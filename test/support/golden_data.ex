defmodule Conveyor.GoldenData do
  @moduledoc """
  A small, hand-written dataset whose dashboard numbers are known exactly (see
  `Conveyor.Metrics.GoldenTest` for the arithmetic). `insert!/2` writes it relative to `now`:

  Current window (last 7 days): 6 builds.
  - CI: 200 ms succeeded (80/100 cache hits), 400 ms succeeded (60/100), 1000 ms failed (10/100)
  - Local: 100 ms succeeded (0/50), 300 ms succeeded (25/50), one build still running

  Previous window (7 to 14 days ago): 4 builds.
  - 200 ms succeeded (40/100), 200 ms failed (20/100), 600 ms succeeded (30/100),
    800 ms succeeded (10/100)

  Plus one 9999 ms build 20 days ago (outside both windows) and one in another project.

  Profile summaries (action phases, ms) exist for the two current CI successes only:
  the 200 ms build has cache check 50, remote execution 100, download outputs 30; the
  400 ms build has cache check 20, queued 40, remote execution 200. Their action
  summaries: TestRunner 9 created / 5 executed and Genrule 3 / 2, then TestRunner 4 / 1;
  profile mnemonics: TestRunner 500 ms and Genrule 100 ms, then TestRunner 250 ms.

  Targets (successful, timed) on the three finished CI/Local builds of each window:
  `//app:slow` 300/400/500 ms now vs 200/200/300 ms before (median doubled), `//lib:ok`
  100 ms in every run, `//app:once` 900 ms in one current run only.
  """

  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo

  @spec insert!(integer(), integer(), DateTime.t()) :: :ok
  def insert!(project_id, other_project_id, now) do
    day = 86_400

    current = [
      row(project_id, now, -1 * day, "succeeded", 200, 80, 100, true),
      row(project_id, now, -2 * day, "succeeded", 400, 60, 100, true),
      row(project_id, now, -3 * day, "failed", 1000, 10, 100, true),
      row(project_id, now, -4 * day, "succeeded", 100, 0, 50, false),
      row(project_id, now, -5 * day, "succeeded", 300, 25, 50, false),
      row(project_id, now, -6 * day, "in_progress", nil, nil, nil, false)
    ]

    previous = [
      row(project_id, now, -8 * day, "succeeded", 200, 40, 100, true),
      row(project_id, now, -9 * day, "failed", 200, 20, 100, true),
      row(project_id, now, -10 * day, "succeeded", 600, 30, 100, false),
      row(project_id, now, -11 * day, "succeeded", 800, 10, 100, false)
    ]

    outside = [
      row(project_id, now, -20 * day, "succeeded", 9999, 99, 100, true),
      row(other_project_id, now, -1 * day, "failed", 9999, 99, 100, true)
    ]

    Repo.insert_all(Invocation, current ++ previous ++ outside)

    [first, second | _] = current

    Repo.insert_all(Conveyor.Invocations.Metrics, [
      metrics(
        first,
        [{"cache check", 50}, {"remote execution", 100}, {"download outputs", 30}],
        [{"TestRunner", 9, 5}, {"Genrule", 3, 2}],
        [{"TestRunner", 500}, {"Genrule", 100}]
      ),
      metrics(
        second,
        [{"cache check", 20}, {"queued", 40}, {"remote execution", 200}],
        [{"TestRunner", 4, 1}],
        [{"TestRunner", 250}]
      )
    ])

    targets =
      Enum.zip(Enum.take(current, 3), [300, 400, 500]) ++
        Enum.zip(Enum.take(previous, 3), [200, 200, 300])

    Repo.insert_all(
      Conveyor.Invocations.Target,
      Enum.flat_map(targets, fn {row, slow} ->
        [target(row, "//app:slow", slow), target(row, "//lib:ok", 100)]
      end) ++ [target(hd(current), "//app:once", 900)]
    )

    :ok
  end

  defp metrics(row, phases, action_data, mnemonics) do
    %{
      invocation_id: row.id,
      build_metrics: %{
        "actionSummary" => %{
          "actionData" =>
            Enum.map(action_data, fn {m, created, executed} ->
              %{
                "mnemonic" => m,
                "actionsCreated" => to_string(created),
                "actionsExecuted" => to_string(executed)
              }
            end)
        }
      },
      profile_summary: %{
        "action_phases" => totals(phases),
        "mnemonics" => totals(mnemonics)
      },
      inserted_at: row.started_at,
      updated_at: row.started_at
    }
  end

  defp totals(pairs),
    do:
      Enum.map(pairs, fn {name, ms} -> %{"name" => name, "count" => 1, "total_ms" => ms * 1.0} end)

  defp target(row, label, duration) do
    %{
      invocation_id: row.id,
      label: label,
      status: "success",
      first_seen_at: row.started_at,
      completed_at: DateTime.add(row.started_at, duration, :millisecond),
      duration_ms: duration
    }
  end

  defp row(project_id, now, offset_s, status, duration, hits, executed, ci?) do
    started = now |> DateTime.add(offset_s, :second) |> DateTime.truncate(:microsecond)
    finished = duration && DateTime.add(started, duration, :millisecond)

    %{
      id: Conveyor.Bep.Replay.uuid(),
      project_id: project_id,
      status: status,
      exit_code_name: exit_name(status),
      exit_code: if(status == "failed", do: 1, else: 0),
      command: "build",
      patterns: ["//..."],
      bazel_version: "9.2.0",
      host: if(ci?, do: "ci-runner-1", else: "mac-1"),
      user_name: if(ci?, do: "ci", else: "alice"),
      started_at: started,
      finished_at: finished,
      duration_ms: duration,
      last_event_seq: 10,
      stream_finished: status != "in_progress",
      lifecycle_finished: status != "in_progress",
      actions_executed: executed,
      remote_cache_hits: hits,
      remote_exec: executed && hits && executed - hits,
      tags: %{"ci" => to_string(ci?), "user" => if(ci?, do: "ci", else: "alice")},
      inserted_at: started,
      updated_at: started
    }
  end

  defp exit_name("succeeded"), do: "SUCCESS"
  defp exit_name("failed"), do: "BUILD_FAILURE"
  defp exit_name(_), do: nil
end
