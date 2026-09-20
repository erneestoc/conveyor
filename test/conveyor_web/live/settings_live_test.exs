defmodule ConveyorWeb.SettingsLiveTest do
  use ConveyorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Conveyor.Projects

  setup do
    %{project: Projects.ensure_default_project!()}
  end

  test "projects and keys: create, rotate, revoke, archive", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "#project-#{project.id}")

    view |> form("#project-form", project: %{slug: "Bad Slug", name: ""}) |> render_submit()
    assert render(view) =~ "must be lowercase"

    view
    |> form("#project-form", project: %{slug: "payments", name: "Payments"})
    |> render_submit()

    payments = Projects.get_project_by_slug("payments")
    assert has_element?(view, "#project-#{payments.id}")

    view
    |> form("#key-form-#{payments.id}", api_key: %{name: "", default_tags: ""})
    |> render_submit()

    assert render(view) =~ "can&#39;t be blank"

    view
    |> form("#key-form-#{payments.id}",
      api_key: %{name: "ci", default_tags: "ci=true, team=infra, junk"}
    )
    |> render_submit()

    assert has_element?(view, "#new-key")

    plaintext =
      view
      |> element("#new-key-plaintext")
      |> render()
      |> String.replace(~r/<[^>]+>/, "")
      |> String.trim()

    assert {:ok, key} = Projects.verify_api_key(plaintext)
    assert key.default_tags == %{"ci" => "true", "team" => "infra"}
    assert has_element?(view, "#key-#{key.id}[data-state=active]")
    view |> element("#dismiss-key") |> render_click()
    refute has_element?(view, "#new-key")

    view |> element("#key-#{key.id} button", "Rotate") |> render_click()
    assert has_element?(view, "#new-key")
    assert has_element?(view, "#expiring-keys")
    [successor] = Projects.list_api_keys(payments) |> Enum.reject(&(&1.id == key.id))
    assert successor.rotated_from_id == key.id

    view |> element("#key-#{key.id} button", "Revoke") |> render_click()
    assert has_element?(view, "#key-#{key.id}[data-state=revoked]")
    refute has_element?(view, "#key-#{key.id} button")

    view |> element("#project-#{payments.id} button", "Archive") |> render_click()
    refute has_element?(view, "#project-#{payments.id}")
    assert has_element?(view, "#nav-settings")
  end

  test "remote cache endpoints can be added and removed", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/settings")

    view
    |> form("#cache-endpoint-form-#{project.id}",
      endpoint: %{host: "bad host", header_name: "", header_value: ""}
    )
    |> render_submit()

    assert render(view) =~ "must look like host or host:port"

    view
    |> form("#cache-endpoint-form-#{project.id}",
      endpoint: %{
        host: "cache.example.com:443",
        header_name: "x-api-key",
        header_value: "s3cret",
        tls_mode: "custom_ca",
        ca_file: "/etc/conveyor/ca.crt",
        endpoint: "grpcs://cas.internal:443",
        bearer_token: "zq9bearer"
      }
    )
    |> render_submit()

    html = render(view)
    assert has_element?(view, "#cache-endpoint-#{project.id}-cache-example-com-443")
    assert html =~ "x-api-key=••••"
    refute html =~ "s3cret"

    assert html =~ "custom_ca → grpcs://cas.internal:443"
    assert html =~ "bearer=••••"
    refute html =~ "zq9bearer"

    assert %{
             "cache.example.com:443" => %{
               "headers" => %{"x-api-key" => "s3cret"},
               "tls" => %{"mode" => "custom_ca", "ca_file" => "/etc/conveyor/ca.crt"},
               "endpoint" => "grpcs://cas.internal:443",
               "bearer_token" => "zq9bearer"
             }
           } = Projects.cache_endpoints(Projects.get_project!(project.id))

    view
    |> form("#cache-endpoint-form-#{project.id}",
      endpoint: %{host: "ok.example.com", endpoint: "http://bad/x"}
    )
    |> render_submit()

    assert render(view) =~ "Endpoint override must look like"

    view
    |> element("#cache-endpoint-#{project.id}-cache-example-com-443 button", "Remove")
    |> render_click()

    refute has_element?(view, "#cache-endpoint-#{project.id}-cache-example-com-443")
    assert Projects.cache_endpoints(Projects.get_project!(project.id)) == %{}
  end

  test "dashboard segments can be added, reordered and removed", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "#segments-#{project.id}", "Using the default segments")

    view
    |> form("#segment-form-#{project.id}", segment: %{name: "Broken", query: "ci:"})
    |> render_submit()

    assert render(view) =~ "Could not save the segment"

    view
    |> form("#segment-form-#{project.id}",
      segment: %{name: "Main CI", query: "ci:true branch:main"}
    )
    |> render_submit()

    view
    |> form("#segment-form-#{project.id}", segment: %{name: "Humans", query: "ai!=true"})
    |> render_submit()

    [main, humans] = Conveyor.Projects.Segments.list(project.id)
    assert has_element?(view, "#segment-row-#{main.id}", "ci:true branch:main")

    view |> element("#segment-row-#{humans.id} button[phx-value-dir=up]") |> render_click()

    assert Enum.map(Conveyor.Projects.Segments.list(project.id), & &1.name) == [
             "Humans",
             "Main CI"
           ]

    view |> element("#segment-row-#{main.id} button[phx-click=delete_segment]") |> render_click()
    refute has_element?(view, "#segment-row-#{main.id}")
    assert has_element?(view, "#audit-log", "segment.create")
    assert has_element?(view, "#audit-log", "segment.delete")
  end

  test "settings actions are audited", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "#audit-log", "Nothing yet")

    view
    |> form("#key-form-#{project.id}", api_key: %{name: "audited", default_tags: ""})
    |> render_submit()

    assert [%{action: "api_key.create", actor: "anonymous", metadata: %{"name" => "audited"}}] =
             Conveyor.Audit.recent(1)

    assert has_element?(view, "#audit-log td", "api_key.create")
  end
end
