defmodule ConveyorWeb.ProjectBoundaryTest do
  @moduledoc """
  The project is the hard boundary: walks every router entry with a project-bound
  parameter and checks that a viewer allowed on project A gets 404 for project B's ids
  and slugs (and 200 for A's, so the substitution is real). A route added to the router
  without an entry in `@fill` fails the test.
  """
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.Accounts.Scope
  alias Conveyor.{FakeOidc, Invocations, Projects, Repo}
  alias Conveyor.Metrics

  @moduletag :capture_log

  setup_all do
    %{issuer: FakeOidc.start()}
  end

  setup %{issuer: issuer} do
    previous = Application.get_env(:conveyor, Conveyor.Accounts)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Accounts, previous) end)

    Application.put_env(
      :conveyor,
      Conveyor.Accounts,
      Keyword.merge(previous,
        mode: :oidc,
        oidc: [
          client_id: FakeOidc.client_id(),
          client_secret: FakeOidc.client_secret(),
          base_url: issuer
        ]
      )
    )

    {:ok, a} = Projects.create_project(%{slug: "alpha", name: "Alpha"})
    {:ok, a} = Projects.put_allowed_groups(a, ["team-a"])
    {:ok, a} = Projects.put_admin_groups(a, ["team-a"])
    {:ok, b} = Projects.create_project(%{slug: "beta", name: "Beta"})
    {:ok, b} = Projects.put_allowed_groups(b, ["team-b"])

    ids =
      Map.new([a, b], fn p ->
        {p.slug, ingest_fixture!("clean_build_and_test", context(p))}
      end)

    keys = Map.new([a, b], fn p -> {p.slug, upload_key(p)} end)

    for p <- [a, b] do
      assert build_conn()
             |> put_req_header("x-api-key", keys[p.slug])
             |> put_req_header("content-type", "text/plain")
             |> put(~p"/api/v1/invocations/#{ids[p.slug]}/artifacts/notes.txt", "hello")
             |> json_response(201)
    end

    FakeOidc.set_claims(%{"sub" => "ua", "email" => "a@example.com", "groups" => ["team-a"]})
    conn = sign_in(build_conn())
    assert redirected_to(conn) == "/"

    %{conn: conn, a: a, b: b, ids: ids, keys: keys}
  end

  defp context(project),
    do: %Conveyor.Ingest.Context{project_id: project.id, project_slug: project.slug}

  defp upload_key(project) do
    {:ok, _, key} = Projects.create_api_key(project, %{name: "u", scopes: ["upload"]})
    key
  end

  defp sign_in(conn) do
    conn = get(conn, ~p"/auth/oidc")
    [location] = get_resp_header(conn, "location")

    {:ok, {{_, 302, _}, headers, _}} =
      :httpc.request(:get, {String.to_charlist(location), []}, [autoredirect: false], [])

    {_, back} = List.keyfind(headers, ~c"location", 0)
    %URI{query: query} = URI.parse(List.to_string(back))
    get(conn, ~p"/auth/oidc/callback?#{URI.decode_query(query)}")
  end

  # Values for every path parameter, per project. `nil` for a route means "not project-bound".
  defp fill(project, id) do
    %{
      "slug" => project.slug,
      "id" => id,
      "kind" => "log",
      "name" => "notes.txt",
      "tab" => "targets"
    }
  end

  defp path_for(route, values) do
    route.path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> name -> Map.fetch!(values, name)
      segment -> segment
    end)
  end

  # Routes without a project-bound parameter are out of scope (and listed so the test
  # documents its coverage); everything else must be walked.
  @unbound [
    "/",
    "/builds",
    "/dashboard",
    "/tests",
    "/settings",
    "/metrics",
    "/health/live",
    "/health/ready"
  ]

  test "every project-bound route is 404 across the boundary and 200 inside it", ctx do
    %{conn: conn, a: a, b: b, ids: ids, keys: keys} = ctx

    routes =
      ConveyorWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.reject(
        &(String.starts_with?(&1.path, ["/auth", "/dev", "/live"]) or &1.path in @unbound)
      )

    assert routes != []

    for route <- routes do
      assert String.contains?(route.path, ":"), "unclassified route #{route.verb} #{route.path}"
      inside = path_for(route, fill(a, ids["alpha"]))
      outside = path_for(route, fill(b, ids["beta"]))
      check(route, conn, inside, outside, keys["alpha"])
    end
  end

  # LiveViews (a `phoenix_live_view` metadata entry) raise NotFoundError from mount;
  # controllers raise it too, and Plug renders both as 404.
  defp check(%{metadata: %{phoenix_live_view: _}} = route, conn, inside, outside, _key) do
    assert {:ok, _view, _html} = live(conn, inside), "#{route.path} inside"

    error = assert_raise(ConveyorWeb.NotFoundError, fn -> live(conn, outside) end)
    assert Plug.Exception.status(error) == 404, "#{route.path} outside"
  end

  defp check(%{verb: :get} = route, conn, inside, outside, _key) do
    assert get(conn, inside).status == 200, "#{route.path} inside"

    error = assert_raise(ConveyorWeb.NotFoundError, fn -> get(conn, outside) end)
    assert Plug.Exception.status(error) == 404, "#{route.path} outside"
  end

  # API uploads authenticate with a key of project A: B's ids are not found with it.
  defp check(%{verb: :put} = route, _conn, inside, outside, key) do
    put_with = fn path ->
      build_conn()
      |> put_req_header("x-api-key", key)
      |> put_req_header("content-type", "application/octet-stream")
      |> put(path, "x")
    end

    assert put_with.(outside).status == 404, "#{route.path} outside"
    assert put_with.(inside).status in [201, 409, 422], "#{route.path} inside"
  end

  test "list, facets, dashboards and previous-build lookups never cross projects", ctx do
    %{conn: conn, a: a, b: b, ids: ids} = ctx
    scope = %Scope{mode: :oidc, user: Conveyor.Accounts.list_users() |> hd(), admin?: false}
    visible = Scope.project_ids(scope)
    assert a.id in visible and b.id not in visible

    # The all-builds page shows only A's build and ignores B's live digests.
    {:ok, view, _} = live(conn, ~p"/builds")
    assert has_element?(view, "#inv-#{ids["alpha"]}")
    refute has_element?(view, "#inv-#{ids["beta"]}")
    send(view.pid, {:invocation_updated, Invocations.get(ids["beta"]) |> Map.from_struct()})
    refute has_element?(view, "#inv-#{ids["beta"]}")
    send(view.pid, {:invocation_updated, Invocations.get(ids["alpha"]) |> Map.from_struct()})
    assert has_element?(view, "#inv-#{ids["alpha"]}")
    refute render(view) =~ "Beta"

    assert Invocations.list(project_ids: [a.id]) |> Enum.map(& &1.id) == [ids["alpha"]]
    assert Invocations.list(project_ids: []) == []
    assert Invocations.get(ids["beta"], project_ids: [a.id]) == nil
    assert Invocations.facets(nil, project_ids: [b.id]) != []
    assert Invocations.facets(nil, project_ids: []) == []

    all = Metrics.Scope.new("7d", nil, [])
    assert Metrics.Dashboard.summary(all).builds == 2
    assert Metrics.Dashboard.summary(Metrics.Scope.restrict(all, [a.id])).builds == 1
    assert Metrics.Dashboard.summary(Metrics.Scope.restrict(all, [])).builds == 0
    assert Metrics.Tests.overview(Metrics.Scope.restrict(all, [a.id])) != []
    assert Metrics.Tests.overview(Metrics.Scope.restrict(all, [])) == []

    {:ok, _view, html} = live(conn, ~p"/dashboard")
    refute html =~ "Beta"

    # Same branch in both projects: the previous build with a log is still per project.
    import Ecto.Query
    ids_list = Map.values(ids)

    Repo.update_all(
      from(i in Invocations.Invocation, where: i.id in ^ids_list),
      set: [exec_log_status: "parsed", tags: %{"branch" => "main"}]
    )

    for {_slug, id} <- ids,
        do: assert(Conveyor.ExecLog.previous_with_log(Invocations.get(id)) == nil)
  end

  test "metrics need an admin session when no scrape token is set", %{conn: conn} do
    assert build_conn() |> get(~p"/metrics") |> response(401)
    assert conn |> get(~p"/metrics") |> response(401)

    FakeOidc.set_claims(%{"sub" => "adm", "email" => "root@example.com", "groups" => ["team-b"]})

    Application.put_env(
      :conveyor,
      Conveyor.Accounts,
      Keyword.put(Application.get_env(:conveyor, Conveyor.Accounts), :admin_emails, [
        "root@example.com"
      ])
    )

    assert build_conn() |> sign_in() |> get(~p"/metrics") |> response(200)
  end
end
