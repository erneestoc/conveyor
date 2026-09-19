defmodule ConveyorWeb.DashboardLiveTest do
  use ConveyorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Conveyor.Projects

  setup do
    project = Projects.ensure_default_project!()
    {100, _} = Mix.Tasks.Conveyor.Seed.seed(project.id, 100, 5, {7, 8, 9})
    %{project: project}
  end

  test "renders all panels, ranges, queries and refreshes on finished builds", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _} = live(conn, ~p"/dashboard")

    for id <-
          ~w(headline segments panel-builds panel-durations panel-cache panel-strategy panel-failures panel-targets panel-users panel-slowest panel-hours panel-versions segment-Local segment-CI) do
      assert has_element?(view, "##{id}"), id
    end

    view |> element("#range-30d") |> render_click()
    assert_patch(view, ~p"/dashboard?range=30d")
    assert has_element?(view, "#range-30d[aria-selected=true]")

    view |> form("#dashboard-search", q: "ci:true") |> render_submit()
    assert_patch(view, ~p"/dashboard?range=30d&q=ci%3Atrue")

    view |> form("#dashboard-search", q: "ci:") |> render_submit()
    assert has_element?(view, "#query-error")

    send(view.pid, {:invocation_updated, %{finalized: true}})
    send(view.pid, {:invocation_updated, %{finalized: true}})
    send(view.pid, {:invocation_updated, %{finalized: false}})
    send(view.pid, :refresh)
    assert has_element?(view, "#headline")

    {:ok, view, _} = live(conn, ~p"/p/#{project.slug}/dashboard?range=24h")
    assert has_element?(view, "#range-24h[aria-selected=true]")
    view |> element("#range-7d") |> render_click()
    assert_patch(view, ~p"/p/#{project.slug}/dashboard?range=7d")

    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/p/nope/dashboard") end
  end

  test "tests page lists health rows and filters", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, ~p"/tests?range=30d")
    assert has_element?(view, "#tests-table")
    assert has_element?(view, "#tests-table tr[data-health]")

    view |> element("#range-90d") |> render_click()
    assert_patch(view, ~p"/tests?range=90d")
    view |> form("#tests-search", q: "ci:true") |> render_submit()
    assert_patch(view, ~p"/tests?range=90d&q=ci%3Atrue")

    {:ok, view, _} = live(conn, ~p"/p/#{project.slug}/tests")
    view |> element("#range-24h") |> render_click()
    assert_patch(view, ~p"/p/#{project.slug}/tests?range=24h")
    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/p/nope/tests") end
  end
end
