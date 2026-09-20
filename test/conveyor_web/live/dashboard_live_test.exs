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
          ~w(headline segments panel-builds panel-durations panel-phases phases-empty panel-cache panel-strategy panel-failures panel-targets panel-users panel-slowest panel-hours panel-queue queue-empty panel-regressions panel-mnemonics panel-cache-mnemonics exec-empty panel-cache-missing panel-non-hermetic panel-remote-bytes remote-bytes-empty panel-versions segment-Local segment-CI) do
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

  test "stat tiles show the change against the previous period", %{conn: conn} do
    {:ok, project} = Projects.create_project(%{slug: "golden-live", name: "Golden"})
    {:ok, other} = Projects.create_project(%{slug: "golden-live-other", name: "Other"})
    Conveyor.GoldenData.insert!(project.id, other.id, DateTime.utc_now())

    {:ok, view, _} = live(conn, ~p"/p/golden-live/dashboard?range=7d")
    assert has_element?(view, "#tile-builds [data-delta='0.5']", "▲ 50%")
    assert has_element?(view, "#tile-p50 [data-delta='-0.25'].text-emerald-600", "▼ 25%")
    assert has_element?(view, "#tile-p90 .text-rose-600", "▲ 3%")
    assert has_element?(view, "#tile-success .text-emerald-600", "▲ 7%")
    assert has_element?(view, "#tile-cache[title], #tile-cache [title='previous period: 25%']")
    assert has_element?(view, "#chart-phases rect[fill='#8b5cf6']")
    refute has_element?(view, "#phases-empty")
    assert has_element?(view, "#chart-queue")
    assert has_element?(view, "#regression--app-slow", "▲ 100%")
    assert has_element?(view, "#panel-mnemonics td", "TestRunner")
    assert has_element?(view, "#chart-hours [data-count='1'][title*='UTC · 1 builds']")
    assert has_element?(view, "#cache-mnemonic-Compile", "33%")
    assert has_element?(view, "#chart-cache-missing")
    assert has_element?(view, "#non-hermetic--app-a-Genrule", "1×")
    assert has_element?(view, "#chart-remote-bytes")
    refute has_element?(view, "#exec-empty")

    # No builds in the previous period: the tiles show no delta at all.
    {:ok, view, _} = live(conn, ~p"/p/golden-live-other/dashboard?range=7d")
    assert has_element?(view, "#tile-builds")
    refute has_element?(view, "#tile-builds [data-delta]")
  end

  test "segment chips narrow the dashboard and compare renders two columns", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _} = live(conn, ~p"/p/#{project.slug}/dashboard?range=30d")
    assert has_element?(view, "#segment-chip-all[aria-selected=true]")
    assert has_element?(view, "#segment-chip-CI[aria-selected=false]")

    view |> element("#segment-chip-CI") |> render_click()
    assert_patch(view, ~p"/p/#{project.slug}/dashboard?range=30d&segment=CI")
    assert has_element?(view, "#segment-chip-CI[aria-selected=true]")
    assert has_element?(view, "#tile-builds", "0 running")

    ci =
      Conveyor.Metrics.Dashboard.summary(
        Conveyor.Metrics.Scope.new("30d", project.id, Conveyor.Query.parse!("ci:true"))
      )

    assert render(element(view, "#tile-builds")) =~ Integer.to_string(ci.builds)

    view |> form("#compare-form", a: "Local", b: "CI") |> render_submit()
    assert_patch(view, ~p"/p/#{project.slug}/dashboard?range=30d&compare=Local%2CCI")
    assert has_element?(view, "#compare-Local #tile-builds-Local")
    assert has_element?(view, "#compare-CI #panel-durations-CI")
    refute has_element?(view, "#segments")

    view |> element("#compare-off") |> render_click()
    assert_patch(view, ~p"/p/#{project.slug}/dashboard?range=30d")
    assert has_element?(view, "#segments")

    # Unknown names are ignored; a saved segment replaces the defaults.
    {:ok, view, _} = live(conn, ~p"/dashboard?segment=Nope&compare=Local,Local")
    assert has_element?(view, "#segment-chip-all[aria-selected=true]")
    refute has_element?(view, "#compare")

    {:ok, _} =
      Conveyor.Projects.Segments.create(project, %{
        "name" => "Main CI",
        "query" => "ci:true branch:main"
      })

    {:ok, view, _} = live(conn, ~p"/p/#{project.slug}/dashboard?segment=Main%20CI")
    assert has_element?(view, "#segment-chip-Main-CI[aria-selected=true]")
    refute has_element?(view, "#segment-chip-CI")
    refute has_element?(view, "#compare-form")
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
