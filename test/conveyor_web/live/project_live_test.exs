defmodule ConveyorWeb.ProjectLiveTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.{FakeOidc, Projects}

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

    {:ok, alpha} = Projects.create_project(%{slug: "alpha", name: "Alpha"})
    {:ok, alpha} = Projects.put_admin_groups(alpha, ["alpha-leads"])
    {:ok, beta} = Projects.create_project(%{slug: "beta", name: "Beta"})
    %{alpha: alpha, beta: beta}
  end

  defp sign_in(claims) do
    FakeOidc.set_claims(claims)
    conn = get(build_conn(), ~p"/auth/oidc")
    [location] = get_resp_header(conn, "location")

    {:ok, {{_, 302, _}, headers, _}} =
      :httpc.request(:get, {String.to_charlist(location), []}, [autoredirect: false], [])

    {_, back} = List.keyfind(headers, ~c"location", 0)
    %URI{query: query} = URI.parse(List.to_string(back))
    get(conn, ~p"/auth/oidc/callback?#{URI.decode_query(query)}")
  end

  test "a project admin manages keys, storage and segments of that project only", %{
    alpha: alpha,
    beta: beta
  } do
    conn = sign_in(%{"sub" => "lead", "email" => "lead@example.com", "groups" => ["alpha-leads"]})

    # The nav offers the page for alpha; the page shows no access controls.
    {:ok, view, _} = live(conn, ~p"/p/alpha")
    assert has_element?(view, "#main-nav a", "Project settings")
    {:ok, view, _} = live(conn, ~p"/p/beta")
    refute has_element?(view, "#main-nav a", "Project settings")

    {:ok, view, _} = live(conn, ~p"/p/alpha/settings")
    assert has_element?(view, "#project-settings-title", "Alpha")
    assert has_element?(view, "#storage-form-#{alpha.id}")
    refute has_element?(view, "#allowed-groups-form-#{alpha.id}")
    refute has_element?(view, "#admin-groups-form-#{alpha.id}")
    refute has_element?(view, "#new-project")

    view
    |> form("#key-form-#{alpha.id}", api_key: %{name: "ci", default_tags: "team=alpha"})
    |> render_submit()

    assert has_element?(view, "#new-key")
    assert [%{name: "ci"}] = Projects.list_api_keys(alpha)

    view
    |> form("#storage-form-#{alpha.id}", %{"retention_days" => "14", "blob_prefix" => ""})
    |> render_submit()

    assert Projects.retention_days(Projects.get_project!(alpha.id)) == 14

    view
    |> form("#segment-form-#{alpha.id}", segment: %{name: "CI", query: "ci:true"})
    |> render_submit()

    assert [%{name: "CI"}] = Conveyor.Projects.Segments.list(alpha.id)
    assert has_element?(view, "#audit-log td", "segment.create")

    # A hidden project_id pointing at another project is not found, not honoured.
    # The LiveView raises and exits; with exits trapped the test sees the call's exit.
    Process.flag(:trap_exit, true)

    assert {{%ConveyorWeb.NotFoundError{}, _}, _} =
             catch_exit(
               render_submit(view, "put_storage", %{
                 "project_id" => beta.id,
                 "retention_days" => "3"
               })
             )

    assert Projects.retention_days(Projects.get_project!(beta.id)) == nil

    # Other projects' pages and the global settings are out of reach.
    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/p/beta/settings") end
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings")

    # A viewer outside the admin group gets nothing.
    other = sign_in(%{"sub" => "dev", "email" => "dev@example.com", "groups" => ["eng"]})
    assert_raise ConveyorWeb.NotFoundError, fn -> live(other, ~p"/p/alpha/settings") end
  end

  test "admin groups also grant visibility of a restricted project", %{alpha: alpha} do
    {:ok, alpha} = Projects.put_allowed_groups(alpha, ["nobody"])
    lead = %Conveyor.Accounts.User{groups: ["alpha-leads"], role: "viewer", email: "l@x"}
    scope = %Conveyor.Accounts.Scope{mode: :oidc, user: lead}
    assert Conveyor.Accounts.Scope.can_view_project?(scope, alpha)
    assert Conveyor.Accounts.Scope.can_admin_project?(scope, alpha)
    refute Conveyor.Accounts.Scope.can_admin_project?(%Conveyor.Accounts.Scope{}, alpha)
  end
end
