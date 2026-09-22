defmodule ConveyorWeb.MultiProjectTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.{Ingest, Projects}

  test "builds, facets, dashboard and tests are scoped to the project in the path" do
    default = Projects.ensure_default_project!()
    {:ok, other} = Projects.create_project(%{slug: "mobile", name: "Mobile"})
    ok_id = ingest_fixture!("clean_build_and_test", context())

    failed_id =
      ingest_fixture!("build_failure", %Ingest.Context{
        project_id: other.id,
        project_slug: other.slug,
        api_key_tags: %{"team" => "mobile"}
      })

    {:ok, view, _} = live(build_conn(), ~p"/p/mobile")
    assert has_element?(view, "#inv-#{failed_id}")
    refute has_element?(view, "#inv-#{ok_id}")
    assert has_element?(view, "#facet-#{:erlang.phash2({"team", "mobile"})}")
    refute has_element?(view, "#facet-#{:erlang.phash2({"scenario", "clean_build_and_test"})}")

    {:ok, view, _} = live(build_conn(), ~p"/p/#{default.slug}")
    assert has_element?(view, "#inv-#{ok_id}")
    refute has_element?(view, "#inv-#{failed_id}")

    {:ok, view, _} = live(build_conn(), ~p"/builds")
    assert has_element?(view, "#inv-#{ok_id}") and has_element?(view, "#inv-#{failed_id}")

    {:ok, _view, html} = live(build_conn(), ~p"/p/mobile/dashboard")
    assert html =~ "Mobile"
    {:ok, _view, html} = live(build_conn(), ~p"/p/mobile/tests")
    assert html =~ "Mobile" or html =~ "tests"

    assert_raise ConveyorWeb.NotFoundError, fn -> live(build_conn(), ~p"/p/nope") end
  end
end
