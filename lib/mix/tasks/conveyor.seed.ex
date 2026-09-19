defmodule Mix.Tasks.Conveyor.Seed do
  @shortdoc "Seeds invocations: fixture replays for browsing, or synthetic rows for volume"
  @moduledoc """
  Two modes.

  `--replay N` pushes the recorded BEP fixtures through the real ingest pipeline (every tab
  of every build is populated: log, targets, tests, actions, timeline, events) and spreads
  them over the last N days with varied users, hosts, branches and build lengths. It starts
  the application without the gRPC and web servers, so it is safe while a dev server runs;
  refresh the browser afterwards.

      mix conveyor.seed --replay 2000 [--days 30] [--concurrency 32] [--project default]

  `--invocations N` inserts synthetic rows directly (statuses, durations, users, tags, cache
  stats only; the builds have no events), for dashboard volume and load tests.

      mix conveyor.seed --invocations 5000 [--days 30] [--project default]
  """
  use Mix.Task

  import Ecto.Query

  alias Conveyor.Invocations.{Invocation, Target, TagKey}
  alias Conveyor.Repo

  @switches [
    invocations: :integer,
    replay: :integer,
    concurrency: :integer,
    days: :integer,
    project: :string
  ]
  @users ~w(alice bob carol dave erin frank grace heidi)
  @hosts ~w(mac-1 mac-2 linux-a linux-b ci-runner-1 ci-runner-2 ci-runner-3)
  @patterns [
    ["//..."],
    ["//app/..."],
    ["//lib:all"],
    ["//server:server"],
    ["//app:app_test", "//lib:all"]
  ]
  @exit_codes [
    {"SUCCESS", 0, "succeeded"},
    {"BUILD_FAILURE", 1, "failed"},
    {"TESTS_FAILED", 3, "failed"},
    {"INTERRUPTED", 8, "aborted"}
  ]
  @failing_targets ~w(//app:flaky_test //server:integration_test //lib:parser_test //app:build_broken)

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    days = Keyword.get(opts, :days, 30)

    if opts[:replay], do: start_app(), else: start_repo()

    project =
      Conveyor.Projects.get_project_by_slug(Keyword.get(opts, :project, "default")) ||
        Conveyor.Projects.ensure_default_project!()

    if n = opts[:replay] do
      ids = Conveyor.Seed.replay(project.id, n, days, Keyword.take(opts, [:concurrency]))

      Mix.shell().info(
        "replayed #{length(ids)} builds over #{days} days into project #{project.slug}"
      )
    else
      n = Keyword.get(opts, :invocations, 1_000)
      {count, targets} = seed(project.id, n, days)

      Mix.shell().info(
        "inserted #{count} invocations and #{targets} failed targets into project #{project.slug}"
      )
    end
  end

  # The ingest pipeline needs the application, but not its listeners: a dev server may be
  # running on the same ports.
  defp start_app do
    Mix.Task.run("app.config")
    grpc = Application.get_env(:conveyor, Conveyor.Grpc, [])
    Application.put_env(:conveyor, Conveyor.Grpc, Keyword.put(grpc, :start_server, false))
    endpoint = Application.get_env(:conveyor, ConveyorWeb.Endpoint, [])
    Application.put_env(:conveyor, ConveyorWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Mix.Task.run("app.start")
  end

  # Only the repo is needed; starting the whole app would also bind the gRPC port.
  defp start_repo do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    case Conveyor.Repo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @doc false
  def seed(project_id, n, days, seed \\ :os.timestamp()) do
    :rand.seed(:exsss, seed)
    now = DateTime.utc_now()

    rows =
      for _ <- 1..n do
        ci? = :rand.uniform() < 0.55
        {exit_name, exit_code, status} = pick_exit(ci?)

        started =
          DateTime.add(now, -:rand.uniform(days * 86_400), :second)
          |> DateTime.truncate(:microsecond)

        duration = duration_ms(ci?, status)
        executed = 50 + :rand.uniform(2_000)

        hits =
          round(executed * if(ci?, do: 0.7, else: 0.4) * (0.6 + :rand.uniform() * 0.5))
          |> min(executed)

        user = Enum.random(@users)
        id = Conveyor.Bep.Replay.uuid()

        %{
          id: id,
          project_id: project_id,
          status: status,
          exit_code_name: exit_name,
          exit_code: exit_code,
          command: if(:rand.uniform() < 0.6, do: "test", else: "build"),
          patterns: Enum.random(@patterns),
          bazel_version: Enum.random(["9.2.0", "9.2.0", "9.1.0", "8.3.1"]),
          host:
            if(ci?,
              do: Enum.random(Enum.slice(@hosts, 4, 3)),
              else: Enum.random(Enum.slice(@hosts, 0, 4))
            ),
          user_name: if(ci?, do: "ci", else: user),
          started_at: started,
          finished_at: DateTime.add(started, duration, :millisecond),
          duration_ms: duration,
          wall_ms: duration,
          analysis_ms: round(duration * 0.15),
          execution_ms: round(duration * 0.8),
          critical_path_ms: round(duration * 0.5),
          last_event_seq: 100,
          stream_finished: true,
          lifecycle_finished: true,
          event_count: 99,
          targets_configured: 20 + :rand.uniform(200),
          targets_completed: 20 + :rand.uniform(200),
          targets_failed: if(status == "failed", do: :rand.uniform(3), else: 0),
          tests_total: 10 + :rand.uniform(50),
          tests_passed: 10 + :rand.uniform(45),
          tests_failed: if(exit_name == "TESTS_FAILED", do: :rand.uniform(3), else: 0),
          tests_flaky: if(:rand.uniform() < 0.1, do: 1, else: 0),
          actions_created: executed + :rand.uniform(500),
          actions_executed: executed,
          remote_cache_hits: hits,
          remote_exec: if(ci?, do: round((executed - hits) * 0.8), else: 0),
          local_exec: if(ci?, do: round((executed - hits) * 0.2), else: executed - hits),
          worker_exec: :rand.uniform(30),
          sandbox_exec: 0,
          tags: %{
            "ci" => to_string(ci?),
            "user" => if(ci?, do: "ci", else: user),
            "team" => Enum.random(~w(infra backend web mobile)),
            "ai" => to_string(:rand.uniform() < 0.3),
            "branch" => Enum.random(~w(main main main feature/x release/2.1))
          },
          inserted_at: started,
          updated_at: started
        }
      end

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(Invocation, &1, on_conflict: :nothing))

    failed = Enum.filter(rows, &(&1.status == "failed"))

    target_rows =
      Enum.flat_map(failed, fn r ->
        for label <- Enum.take_random(@failing_targets, r.targets_failed) do
          %{
            invocation_id: r.id,
            label: label,
            aspect: "",
            status: "failed",
            test_status: if(r.exit_code_name == "TESTS_FAILED", do: "FAILED", else: nil)
          }
        end
      end)

    target_rows
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(Target, &1, on_conflict: :nothing))

    tag_rows =
      rows
      |> Enum.flat_map(fn r -> Enum.map(r.tags, fn {k, v} -> {k, v} end) end)
      |> Enum.frequencies()
      |> Enum.map(fn {{k, v}, c} ->
        %{project_id: project_id, key: k, value: v, count: c, last_seen_at: now}
      end)

    Repo.insert_all(TagKey, tag_rows,
      on_conflict: [inc: [count: 0]],
      conflict_target: [:project_id, :key, :value]
    )

    _ = from(t in TagKey, where: t.project_id == ^project_id) |> Repo.aggregate(:count)
    {length(rows), length(target_rows)}
  end

  defp pick_exit(ci?) do
    r = :rand.uniform()

    cond do
      r < if(ci?, do: 0.82, else: 0.7) -> Enum.at(@exit_codes, 0)
      r < 0.9 -> Enum.at(@exit_codes, 1)
      r < 0.97 -> Enum.at(@exit_codes, 2)
      true -> Enum.at(@exit_codes, 3)
    end
  end

  # Log-normal-ish durations: CI builds are longer and wider than local incremental builds.
  defp duration_ms(ci?, status) do
    base = if ci?, do: 240_000, else: 20_000
    spread = :math.exp(:rand.normal() * 0.9)
    ms = round(base * spread)
    if status == "aborted", do: div(ms, 3), else: max(ms, 500)
  end
end
