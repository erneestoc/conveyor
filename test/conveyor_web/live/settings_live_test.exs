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
end
