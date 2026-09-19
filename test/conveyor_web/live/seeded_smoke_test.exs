defmodule ConveyorWeb.SeededSmokeTest do
  use ConveyorWeb.LiveCase, async: false

  @moduletag timeout: 120_000

  # Realistic data through the real pipeline, then every page and tab: this is the test
  # that catches values the fixtures never produce (empty tags, odd hosts, long logs).
  test "every page renders and every facet toggles on seeded data" do
    project = Conveyor.Projects.ensure_default_project!()
    ids = Conveyor.Seed.replay(project.id, 24, 5, concurrency: 8, seed: {9, 9, 9})
    big = Conveyor.Seed.big_log(project.id, 1)

    for path <- ["/", "/dashboard", "/tests", "/dashboard?range=30d"] do
      {:ok, _view, html} = live(build_conn(), path)
      refute html =~ "query-error"
    end

    {:ok, view, html} = live(build_conn(), ~p"/")
    facet_ids = Regex.scan(~r/id="(facet-\d+)"/, html) |> Enum.map(&List.last/1) |> Enum.uniq()
    assert length(facet_ids) > 5

    for id <- Enum.take(facet_ids, 12) do
      view |> element("##{id}") |> render_click()
      assert_patch(view)
      refute has_element?(view, "#query-error"), "#{id} produced a query error"
      view |> element("##{id}") |> render_click()
      assert_patch(view)
    end

    for id <- Enum.take(ids, 3) ++ [big],
        tab <- ~w(overview log timeline targets tests actions metrics details events) do
      path = if tab == "overview", do: "/invocation/#{id}", else: "/invocation/#{id}/#{tab}"
      {:ok, _view, html} = live(build_conn(), path)
      assert html =~ "invocation" or html =~ id
    end

    conn = get(build_conn(), ~p"/invocation/#{big}/download/log")
    assert String.to_integer(hd(get_resp_header(conn, "x-log-bytes"))) >= 1024 * 1024
  end
end
