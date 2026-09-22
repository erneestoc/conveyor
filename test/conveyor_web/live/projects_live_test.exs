defmodule ConveyorWeb.ProjectsLiveTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.{Ingest, Projects}

  test "the root lists the projects the viewer may see with their recent numbers" do
    default = Projects.ensure_default_project!()
    {:ok, mobile} = Projects.create_project(%{slug: "mobile", name: "Mobile"})
    {:ok, hidden} = Projects.create_project(%{slug: "hidden", name: "Hidden"})
    {:ok, _} = Projects.put_allowed_groups(hidden, ["nobody"])
    {:ok, _empty} = Projects.create_project(%{slug: "empty", name: "Empty"})

    ok_id = ingest_fixture!("clean_build_and_test", context())

    failed_id =
      ingest_fixture!("build_failure", %Ingest.Context{
        project_id: mobile.id,
        project_slug: mobile.slug
      })

    # Open mode without an admin token: everyone is an admin, restricted projects included.
    {:ok, view, html} = live(build_conn(), ~p"/")
    assert has_element?(view, "#project-card-#{default.id} a", "Settings")
    assert has_element?(view, "#project-card-#{mobile.id}")
    assert has_element?(view, "#project-card-#{hidden.id}")
    assert has_element?(view, "#project-card-#{mobile.id} a[href='/invocation/#{failed_id}']")
    assert has_element?(view, "#project-card-#{default.id} a[href='/invocation/#{ok_id}']")
    assert html =~ "No builds yet"
    refute has_element?(view, "#inv-#{ok_id}")
    assert has_element?(view, "#all-builds-link")

    # The cross-project list moved to /builds and the nav points there.
    {:ok, view, _} = live(build_conn(), ~p"/builds")
    assert has_element?(view, "#inv-#{ok_id}") and has_element?(view, "#inv-#{failed_id}")
    assert has_element?(view, "#main-nav a[href='/builds']", "Builds")

    # With an admin token set, an anonymous viewer sees only unrestricted projects.
    previous = Application.get_env(:conveyor, Conveyor.Accounts)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Accounts, previous) end)
    Application.put_env(:conveyor, Conveyor.Accounts, Keyword.put(previous, :admin_token, "t"))
    {:ok, view, _} = live(build_conn(), ~p"/")
    refute has_element?(view, "#project-card-#{hidden.id}")
    assert has_element?(view, "#project-card-#{mobile.id}")
    refute has_element?(view, "#project-card-#{mobile.id} a", "Settings")
  end
end
