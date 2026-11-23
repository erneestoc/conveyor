defmodule ConveyorWeb.RbeLiveTest do
  use ConveyorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Conveyor.{ExecLog, ExecLogBuilder, Projects, Repo}
  alias Conveyor.Invocations.{Invocation, Metrics}
  alias Conveyor.Rbe.{Groups, Settings}

  setup do
    %{
      project: Projects.ensure_default_project!(),
      t0: DateTime.add(DateTime.utc_now(), -600, :second)
    }
  end

  defp build!(project, start, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invocation{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          status: "succeeded",
          tags: %{"commit" => "abc", "pipeline" => "run-1"},
          host: "ci-1",
          critical_path_ms: 2000,
          execution_ms: 3000,
          inserted_at: start,
          updated_at: start,
          started_at: start,
          finished_at: DateTime.add(start, 20, :second)
        },
        attrs
      )
    )
  end

  defp store!(inv, opts \\ []) do
    {:ok, parsed} =
      [id: inv.id, base: inv.started_at]
      |> Keyword.merge(opts)
      |> ExecLogBuilder.log()
      |> ExecLog.parse()

    ExecLog.store!(inv, parsed)
  end

  test "without logs: the coverage line, how to enable them, and the bound", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    inv = build!(p, t0)

    Repo.insert!(%Metrics{
      invocation_id: inv.id,
      build_metrics: %{
        "actionSummary" => %{
          "runnerCount" => [
            %{"name" => "linux-sandbox", "count" => 8},
            %{"name" => "remote cache hit", "count" => 2}
          ],
          "actionData" => [
            %{
              "mnemonic" => "GoCompilePkg",
              "actionsExecuted" => "10",
              "actionsCreated" => "12",
              "userTime" => "4s"
            }
          ]
        }
      }
    })

    {:ok, view, _html} = live(conn, ~p"/p/#{p.slug}/duplicate-work")

    for id <-
          ~w(rbe-coverage rbe-enable panel-rbe-fleet rbe-fleet-share rbe-fleet-runners rbe-fleet-hosts rbe-fleet-mnemonics rbe-settings rbe-settings-form) do
      assert has_element?(view, "##{id}"), id
    end

    refute has_element?(view, "#rbe-headline")
    assert has_element?(view, "#rbe-empty")
    assert view |> element("#rbe-ci-snippet-empty-text") |> render() =~ "x-api-key"
    assert render(view) =~ "0 of 1 finished builds"
    assert render(view) =~ "GoCompilePkg"
  end

  test "the cold-machines tile shows when it differs from the sequential duplicates", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    for i <- 0..4 do
      store!(build!(p, DateTime.add(t0, i * 60, :second), %{host: "ci-1"}))
    end

    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    assert view |> element("#tile-cold") |> render() =~ "per logged day"
    refute view |> element("#tile-cache-gap") |> render() =~ "(all of it)"
  end

  test "with logs: headline tiles, tables, range, settings", %{conn: conn, project: p, t0: t0} do
    {:ok, p} = Settings.put(p, %{"pipeline_key" => "pipeline"})
    a = build!(p, t0)
    store!(a)

    store!(build!(p, DateTime.add(t0, 200, :millisecond)),
      each: fn s, i -> if i == 5, do: %{s | args: s.args ++ ["--x"]}, else: s end
    )

    store!(build!(p, DateTime.add(t0, 60, :second), %{host: "ci-2"}))

    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")

    for id <-
          ~w(rbe-headline tile-cache-gap tile-racing tile-hit-rate tile-not-remotable tile-parallelism panel-cache-gap gap-same gap-cold gap-total rbe-ci-snippet rbe-ci-snippet-copy rbe-reread-button panel-rbe-mnemonics mnemonic-TestRunner panel-rbe-targets rbe-target-0 panel-rbe-pipelines panel-rbe-near rbe-near-0 rbe-fallback-keys panel-rbe-fleet) do
      assert has_element?(view, "##{id}"), id
    end

    # every sequential duplicate is on a host's first three builds: no tile repeats the
    # headline, the row inside it says so
    refute has_element?(view, "#tile-cold")
    assert view |> element("#tile-cache-gap") |> render() =~ "(all of it)"

    refute has_element?(view, "#panel-rbe-projects")
    # a project outside any group has no "across projects" row
    refute has_element?(view, "#gap-cross")
    # the two answers of the page lead it, per day, with the window's total under them
    assert view |> element("#tile-cache-gap-value") |> render() =~ ~r/>\s*6\s*</
    assert view |> element("#tile-cache-gap") |> render() =~ "core-s per logged day"
    assert view |> element("#tile-cache-gap-days") |> render() =~ ~r/1 of \d days have logs/

    for id <- ~w(hit-rate-today hit-rate-perfect-cache hit-rate-in-flight) do
      assert view |> element("##{id}") |> render() =~ "%"
    end

    tile = view |> element("#tile-hit-rate") |> render()
    assert tile =~ "perfect cache" and tile =~ "with in-flight deduplication"
    refute tile =~ "ideal"
    # small tiles carry the short standing, the headline tiles the long one
    refute tile =~ "cores as stated"
    assert view |> element("#tile-racing") |> render() =~ "exact wall · cores as stated"
    # metrics, not advice: each tile says what its number is, and a help line which
    # mechanism addresses the class
    cache_tile = view |> element("#tile-cache-gap") |> render()
    assert cache_tile =~ "Sequential duplicates"
    assert cache_tile =~ "Executed although the same action had already finished elsewhere."
    racing_tile = view |> element("#tile-racing") |> render()
    assert racing_tile =~ "Racing duplicates"
    assert racing_tile =~ "Executed while the same action was still running elsewhere."
    assert has_element?(view, "#tile-cache-gap-help")
    assert has_element?(view, "#tile-racing-help")
    assert has_element?(view, "h1", "Duplicate work")
    assert page_title(view) =~ "Duplicate work"

    assert has_element?(
             view,
             ~s|#main-nav a[href="/p/#{p.slug}/duplicate-work"]|,
             "Duplicate work"
           )

    refute render(view) =~ "opportunity"
    refute render(view) =~ "recovers"

    # the CI recipe names the address the page was reached at and never a real key
    snippet = view |> element("#rbe-ci-snippet-text") |> render()
    assert snippet =~ "http://www.example.com/api/v1/invocations/$ID/artifacts/execution.log.zst"
    assert snippet =~ "$CONVEYOR_UPLOAD_KEY"
    assert snippet =~ "HTTP $code"
    # no key that may upload yet: the panel says so; an ingest key does not count
    {:ok, _, _} = Projects.create_api_key(p, %{name: "bes", scopes: ["ingest", "read"]})
    assert has_element?(view, "#rbe-ci-snippet-no-key")
    assert snippet =~ "build:ci --execution_log_compact_file"
    refute snippet =~ "conveyor_"
    html = render(view)
    assert html =~ "3 of 3 finished builds"
    assert view |> element("#gap-total") |> render() =~ "6.0s"
    assert view |> element("#tile-parallelism") |> render() =~ "3.0×"

    {:ok, _, _} = Projects.create_api_key(p, %{name: "ci", scopes: ["upload"]})
    view |> element("#rbe-range-24h") |> render_click()
    assert_patch(view, ~p"/p/#{p.slug}/duplicate-work?range=24h")
    assert has_element?(view, "#rbe-range-24h[aria-pressed=true]")
    assert has_element?(view, "#rbe-ci-snippet-has-key")
    refute has_element?(view, "#rbe-ci-snippet-no-key")

    view
    |> form("#rbe-settings-form", %{
      "cores" => "TestRunner=4",
      "tolerance_s" => "5",
      "cache_group" => "mono"
    })
    |> render_submit()

    p = Projects.get_project!(p.id)
    assert Settings.get(p).cores == %{"TestRunner" => 4.0}
    assert Groups.name(p) == "mono"
    assert has_element?(view, "#rbe-group-link")
    assert view |> element("#mnemonic-TestRunner") |> render() =~ "project setting"

    view |> form("#rbe-settings-form", %{"cores" => "nonsense"}) |> render_submit()
    assert render(view) =~ "cores must look like"
  end

  test "a cache group: its page, its projects, and the JSON of each", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    {:ok, other} = Projects.create_project(%{slug: "other-app", name: "Other app"})
    {:ok, p} = Groups.put(p, "mono")
    {:ok, other} = Groups.put(other, "mono")
    store!(build!(p, t0))
    store!(build!(other, DateTime.add(t0, 60, :second)))

    {:ok, view, _} = live(conn, ~p"/groups/mono/duplicate-work")
    assert has_element?(view, "#panel-rbe-projects")
    assert has_element?(view, "#rbe-project-#{other.id}")
    assert has_element?(view, "#rbe-from-#{other.id}")
    assert view |> element("#rbe-subtitle") |> render() =~ "2 projects"
    assert view |> element("#gap-cross") |> render() =~ "6.0s"
    refute has_element?(view, "#rbe-settings")

    # the projects of a group: found by name, sorted by a column, paged
    assert view |> element("#rbe-projects-count") |> render() =~ "2 of 2 projects"
    assert has_element?(view, "#rbe-projects-total")
    assert has_element?(view, "#rbe-projects-sort-wasted", "↓")
    refute has_element?(view, "#rbe-projects-pages")

    view |> form("#rbe-projects-filter", %{"q" => "other"}) |> render_change()
    assert has_element?(view, "#rbe-project-#{other.id}")
    refute has_element?(view, "#rbe-project-#{p.id}")
    assert view |> element("#rbe-projects-count") |> render() =~ "1 of 2 projects"

    view |> form("#rbe-projects-filter", %{"q" => "zzz"}) |> render_change()
    assert has_element?(view, "#rbe-projects-none")
    view |> form("#rbe-projects-filter", %{"q" => ""}) |> render_change()

    for sort <- ~w(name racing own others shared) do
      view |> element("#rbe-projects-sort-#{sort}") |> render_click()
      assert has_element?(view, "#rbe-projects-sort-#{sort} span")
    end

    assert render_click(view, "projects_sort", %{"sort" => "bogus"}) =~ "rbe-projects-sort-wasted"
    assert has_element?(view, "#rbe-projects-sort-wasted span")
    render_click(view, "projects_page", %{"page" => "7"})
    render_click(view, "projects_page", %{"page" => "x"})
    assert has_element?(view, "#rbe-project-#{other.id}")

    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/groups/nope/duplicate-work") end

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(conn, ~p"/groups/nope/duplicate-work/json")
    end

    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/p/nope/duplicate-work/json") end

    assert %{
             "range" => "7d",
             "report" => %{"cache" => %{"cross_project" => %{"n" => 12}}, "members" => 2}
           } =
             conn |> get(~p"/groups/mono/duplicate-work/json") |> json_response(200)

    assert %{"range" => "24h", "report" => %{"cache" => %{"gap" => %{"ms" => 6000}}}} =
             conn |> get(~p"/p/#{other.slug}/duplicate-work/json?range=24h") |> json_response(200)

    # an API key reads its own project; the other project of the group has no name there
    {:ok, _, key} = Projects.create_api_key(other, %{name: "reader", scopes: ["read"]})

    body =
      build_conn()
      |> put_req_header("x-api-key", key)
      |> get(~p"/api/v1/duplicate-work")
      |> json_response(200)

    assert [%{"name" => "Other app", "from" => [%{"name" => "other projects", "id" => nil}]}] =
             body["report"]["projects"]["rows"]

    refute inspect(body) =~ "Default"
    assert build_conn() |> get(~p"/api/v1/duplicate-work") |> json_response(401)

    # The addresses from before the rename: the JSON paths and the API path answer the
    # same body as the new ones.
    for {old, new} <- [
          {~p"/groups/mono/rbe/json", ~p"/groups/mono/duplicate-work/json"},
          {~p"/groups/mono/rbe/json?range=24h", ~p"/groups/mono/duplicate-work/json?range=24h"},
          {~p"/p/#{other.slug}/rbe/json?range=24h",
           ~p"/p/#{other.slug}/duplicate-work/json?range=24h"}
        ] do
      # `days` is the window's length up to the moment of the request
      body = fn path ->
        conn |> get(path) |> json_response(200) |> update_in(["report"], &Map.delete(&1, "days"))
      end

      assert body.(old) == body.(new)
    end

    with_key = fn path ->
      build_conn()
      |> put_req_header("x-api-key", key)
      |> get(path)
      |> json_response(200)
      |> update_in(["report"], &Map.delete(&1, "days"))
    end

    assert with_key.(~p"/api/v1/rbe?range=24h") == with_key.(~p"/api/v1/duplicate-work?range=24h")
    assert with_key.(~p"/api/v1/rbe")["range"] == "7d"
    assert build_conn() |> get(~p"/api/v1/rbe") |> json_response(401)
    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/groups/nope/rbe/json") end
    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/p/nope/rbe/json") end
  end

  test "the page addresses from before the rename redirect, keeping the query string", ctx do
    %{conn: conn, project: p} = ctx
    {:ok, p} = Groups.put(p, "mono")

    assert conn |> get(~p"/p/#{p.slug}/rbe") |> redirected_to(301) ==
             ~p"/p/#{p.slug}/duplicate-work"

    assert conn |> get(~p"/p/#{p.slug}/rbe?range=24h") |> redirected_to(301) ==
             ~p"/p/#{p.slug}/duplicate-work?range=24h"

    assert conn |> get(~p"/groups/mono/rbe") |> redirected_to(301) ==
             ~p"/groups/mono/duplicate-work"

    assert conn |> get(~p"/groups/mono/rbe?range=30d") |> redirected_to(301) ==
             ~p"/groups/mono/duplicate-work?range=30d"

    # the redirect lands on the page, in the window asked for
    to = conn |> get(~p"/p/#{p.slug}/rbe?range=24h") |> redirected_to(301)
    {:ok, view, _} = live(conn, to)
    assert has_element?(view, "#rbe-range-24h[aria-pressed=true]")
    {:ok, view, _} = live(conn, conn |> get(~p"/groups/mono/rbe") |> redirected_to(301))
    assert has_element?(view, "#rbe-subtitle", "cache group mono")

    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/p/nope/rbe") end
    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/groups/nope/rbe") end
  end
end
