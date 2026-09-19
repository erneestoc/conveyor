defmodule ConveyorWeb.TimelineTest do
  use ConveyorWeb.LiveCase, async: false

  alias ConveyorWeb.Timeline

  test "builds rows from phases, tests and actions" do
    start = ~U[2026-09-18 10:00:00Z]

    inv = %{
      started_at: start,
      finished_at: ~U[2026-09-18 10:01:00Z],
      analysis_ms: 5_000,
      execution_ms: 50_000
    }

    tests = [
      %{
        label: "//a:t",
        shard: 1,
        attempt: 1,
        started_at: DateTime.add(start, 6),
        duration_ms: 2_000,
        status: "PASSED"
      },
      %{label: "//a:t", shard: 2, attempt: 2, started_at: nil, duration_ms: 1, status: "FAILED"}
    ]

    actions = [
      %{
        mnemonic: "Javac",
        label: "//b:c",
        primary_output: nil,
        started_at: DateTime.add(start, 7),
        duration_ms: 500,
        success: false,
        exit_code: 1
      }
    ]

    %{rows: rows, span_ms: 60_000, truncated: 0} = Timeline.rows(inv, tests, actions)
    assert Enum.map(rows, & &1.kind) == [:phase, :phase, :test, :action]
    assert Enum.at(rows, 2).start_ms == 6_000 and Enum.at(rows, 3).class =~ "rose"

    assert %{rows: [], start: nil} =
             Timeline.rows(
               %{started_at: nil, finished_at: nil, analysis_ms: nil, execution_ms: nil},
               [],
               []
             )

    many =
      for i <- 1..450,
          do: %{
            label: "//t#{i}",
            shard: 1,
            attempt: 1,
            started_at: DateTime.add(start, i),
            duration_ms: 10,
            status: "PASSED"
          }

    assert %{truncated: 50} = Timeline.rows(inv, many, [])
  end

  test "timeline tab renders for a real build and updates live", %{conn: conn} do
    id = ingest_fixture!("clean_build_and_test", context())
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/timeline")
    assert has_element?(view, "#timeline svg g[data-kind=test]")
    assert has_element?(view, "#timeline g[data-kind=phase]")

    detail = %{
      invocation: %{id: id},
      targets: [],
      tests: [],
      actions: [
        %{
          seq: 777,
          mnemonic: "Genrule",
          label: "//x:y",
          success: true,
          exit_code: 0,
          started_at: DateTime.utc_now(),
          duration_ms: 5
        }
      ]
    }

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Conveyor.Ingest.invocation_topic(id),
      {:invocation_detail, detail}
    )

    assert render(view) =~ "//x:y"

    empty =
      Conveyor.Repo.insert!(%Conveyor.Invocations.Invocation{
        id: Conveyor.Bep.Replay.uuid(),
        project_id: context().project_id
      })

    {:ok, view, _} = live(conn, ~p"/invocation/#{empty.id}/timeline")
    assert render(view) =~ "Nothing to draw yet"
  end
end
