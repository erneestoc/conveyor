defmodule Conveyor.Seed do
  @moduledoc """
  Realistic browsing data. Replays the recorded BEP fixtures through the real ingest
  pipeline, so every invocation has a log, targets, tests, actions, named sets, metrics and
  raw events, then spreads the builds over the last N days (weekday and working-hour
  weighted) with varied users, hosts, branches, teams and Bazel versions, scales build
  lengths and action counters to CI-like and local-like distributions (per-action detail
  stays the fixture's), and rebuilds the project's tag facets.

      Conveyor.Seed.replay(project_id, 2_000, 30)

  Used by `mix conveyor.seed --replay N`.
  """

  import Ecto.Query

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Conveyor.Invocations.{Action, Invocation, Target, TestResult}
  alias Conveyor.Repo
  alias Google.Devtools.Build.V1, as: V1

  @fixtures_dir "test/fixtures/bep"
  @weights [
    clean_build_and_test: 30,
    cached_build_and_test: 30,
    remote_cache_upload: 8,
    build_only_verbose: 8,
    test_failure: 10,
    build_failure: 7,
    flaky_test: 4,
    analysis_failure: 3
  ]
  @users ~w(alice bob carol dave erin frank grace heidi)
  @branches ~w(main main main main main feature/cache-keys feature/ui-polish release/2.1 fix/flaky-parser)
  @teams ~w(infra backend web mobile)
  @versions ~w(9.2.0 9.2.0 9.2.0 9.1.0 8.3.1)

  @doc """
  Ingests `n` fixture replays into the project and shapes them over the last `days` days.
  Options: `:concurrency` (default 32), `:seed` (random seed, for reproducible data).
  Returns the invocation ids.
  """
  @spec replay(integer(), pos_integer(), pos_integer(), keyword()) :: [String.t()]
  def replay(project_id, n, days, opts \\ []) do
    :rand.seed(:exsss, Keyword.get(opts, :seed, :os.timestamp()))
    project = Repo.get!(Conveyor.Projects.Project, project_id)
    ctx = %Ingest.Context{project_id: project.id, project_slug: project.slug}

    events =
      Map.new(@weights, fn {name, _} ->
        {name, Fixture.read!(Path.join([File.cwd!(), @fixtures_dir, "#{name}.bep"]))}
      end)

    plans = for _ <- 1..n, do: plan(days)

    ids =
      plans
      |> Task.async_stream(
        fn plan ->
          id = ingest!(ctx, events[plan.fixture])
          shape!(id, plan)
          id
        end,
        max_concurrency: Keyword.get(opts, :concurrency, 32),
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, id} -> id end)

    Conveyor.Ingest.TagCounter.flush()
    rebuild_tag_keys!(project.id)
    ids
  end

  @doc """
  Ingests one CI build whose log is about `mb` megabytes of Bazel-like output (progress
  bars rewritten with cursor movement, colours, warnings, long compiler lines), for
  exercising the log viewer. Returns the invocation id.
  """
  @spec big_log(integer(), pos_integer(), keyword()) :: String.t()
  def big_log(project_id, mb, opts \\ []) do
    :rand.seed(:exsss, Keyword.get(opts, :seed, {7, 7, 7}))
    project = Repo.get!(Conveyor.Projects.Project, project_id)
    ctx = %Ingest.Context{project_id: project.id, project_slug: project.slug}
    events = Fixture.read!(Path.join([File.cwd!(), @fixtures_dir, "clean_build_and_test.bep"]))
    {head, tail} = Enum.split_while(events, &(not match?({:finished, _}, &1.payload)))

    progress =
      Stream.unfold(0, fn bytes ->
        if bytes >= mb * 1024 * 1024,
          do: nil,
          else:
            (
              c = log_chunk()
              {c, bytes + byte_size(c)}
            )
      end)
      |> Stream.with_index(1)
      |> Enum.map(fn {text, n} ->
        %BuildEventStream.BuildEvent{
          id: %BuildEventStream.BuildEventId{
            id: {:progress, %BuildEventStream.BuildEventId.ProgressId{opaque_count: 100_000 + n}}
          },
          payload: {:progress, %BuildEventStream.Progress{stderr: text}}
        }
      end)

    id = ingest!(ctx, head ++ progress ++ tail)
    plan = %{plan(1) | ci?: true, user: "ci", host: "ci-runner-1", branch: "main", scale: 400.0}
    shape!(id, plan)
    Conveyor.Ingest.TagCounter.flush()
    rebuild_tag_keys!(project.id)
    id
  end

  @mnemonics ~w(Compiling Linking Testing Executing\ genrule Bundling Packaging)
  @dirs ~w(src/server src/client/web lib/core lib/net third_party/absl third_party/grpc tools/build)

  # ~64 KB of terminal output: a curses progress bar (later erased with cursor-up, the
  # way Bazel does), interleaved with coloured INFO/WARNING lines and compiler chatter.
  defp log_chunk do
    total = 4_000 + :rand.uniform(6_000)

    1..60
    |> Enum.map(fn _ ->
      done = :rand.uniform(total)

      bar =
        Enum.map_join(1..8, "", fn _ ->
          "[#{done} / #{total}] #{Enum.random(@mnemonics)} #{path()}; #{:rand.uniform(30)}s remote\n"
        end)

      output =
        case :rand.uniform(10) do
          1 ->
            "\e[33mWARNING:\e[0m #{path()}:#{:rand.uniform(900)}:#{:rand.uniform(80)}: unused variable 'tmp_#{:rand.uniform(99)}' [-Wunused-variable]\n"

          2 ->
            "\e[32mINFO:\e[0m From #{Enum.random(@mnemonics)} #{path()}:\n" <>
              String.duplicate(
                "  in file included from #{path()}:#{:rand.uniform(500)},\n",
                :rand.uniform(4)
              )

          3 ->
            "#{path()}: note: candidate template ignored: could not match '#{String.duplicate("std::vector<", 3)}T>>>' against '#{String.duplicate("absl::Span<", 2)}U>>' " <>
              String.duplicate("(instantiated from #{path()}) ", 20) <> "\n"

          4 ->
            "\e[1mTarget //#{Enum.random(@dirs)}:#{Enum.random(~w(server client core net all))} up-to-date:\e[0m\n  bazel-bin/#{path()}\n"

          _ ->
            ""
        end

      # Erase the bar before the next update, as a curses terminal would.
      bar <> "\e[8A\e[K" <> output
    end)
    |> IO.iodata_to_binary()
  end

  defp path do
    "#{Enum.random(@dirs)}/#{Enum.random(~w(handler stream codec parser router scheduler cache index))}_#{:rand.uniform(40)}.#{Enum.random(~w(cc h go java ts))}"
  end

  # Every random decision for one build, made up front so the ingest tasks stay simple.
  defp plan(days) do
    ci? = :rand.uniform() < 0.55
    user = Enum.random(@users)

    %{
      fixture: weighted(@weights),
      ci?: ci?,
      user: if(ci?, do: "ci", else: user),
      host:
        if(ci?,
          do: "ci-runner-#{:rand.uniform(6)}",
          else: "#{user}-#{Enum.random(~w(mbp linux))}"
        ),
      branch: if(ci?, do: Enum.random(@branches), else: Enum.random(@branches -- ["main"])),
      team: Enum.random(@teams),
      version: Enum.random(@versions),
      started_at: started_at(days),
      # Fixture builds take seconds; CI builds are minutes, local incremental builds tens
      # of seconds, both log-normal.
      scale: (if(ci?, do: 40, else: 4) * :math.exp(:rand.normal() * 0.8)) |> max(1.0)
    }
  end

  defp weighted(weights) do
    total = weights |> Keyword.values() |> Enum.sum()
    pick = :rand.uniform(total)

    Enum.reduce_while(weights, 0, fn {name, w}, acc ->
      if pick <= acc + w, do: {:halt, name}, else: {:cont, acc + w}
    end)
  end

  # Mostly weekdays, mostly working hours, never in the future.
  defp started_at(days) do
    now = DateTime.utc_now()
    date = Date.add(Date.utc_today(), -(:rand.uniform(days) - 1))

    date =
      if Date.day_of_week(date) >= 6 and :rand.uniform() < 0.7,
        do: Date.add(date, -(Date.day_of_week(date) - 5)),
        else: date

    hour = (:rand.normal() * 3 + 14) |> round() |> max(0) |> min(23)
    time = Time.new!(hour, :rand.uniform(60) - 1, :rand.uniform(60) - 1)
    at = DateTime.new!(date, time)
    if DateTime.compare(at, now) == :gt, do: DateTime.add(at, -1, :day), else: at
  end

  defp ingest!(ctx, events) do
    id = Replay.uuid()
    stream_id = %V1.StreamId{build_id: Replay.uuid(), invocation_id: id, component: :TOOL}

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {event, seq} ->
      :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id, seq, event))
    end)

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id, length(events) + 1, marker))
    id
  end

  # Moves the build to its planned time (targets, tests and actions shift with it), scales
  # the build-level durations and sets who ran it where.
  defp shape!(id, plan) do
    inv = Repo.get!(Invocation, id)
    # Tests and actions carry event timestamps; targets are stamped with the ingest clock.
    secs = DateTime.diff(plan.started_at, inv.started_at || inv.inserted_at, :second) * 1.0
    wall_secs = DateTime.diff(plan.started_at, inv.inserted_at, :second) * 1.0
    scale = fn ms -> ms && max(round(ms * plan.scale), 500) end
    duration = scale.(inv.duration_ms || 1_000)
    finished = DateTime.add(plan.started_at, duration, :millisecond)

    tags =
      inv.tags
      |> Map.delete("scenario")
      |> Map.merge(%{
        "user" => plan.user,
        "ci" => to_string(plan.ci?),
        "branch" => plan.branch,
        "team" => plan.team,
        "host" => plan.host,
        "bazel_version" => plan.version,
        "build_user" => plan.user,
        "build_host" => plan.host
      })

    workspace_status =
      inv.workspace_status
      |> Map.replace("BUILD_USER", plan.user)
      |> Map.replace("BUILD_HOST", plan.host)

    home =
      cond do
        plan.ci? -> "/home/ci/work"
        String.ends_with?(plan.host, "linux") -> "/home/#{plan.user}/src"
        true -> "/Users/#{plan.user}/src"
      end

    Repo.update_all(from(i in Invocation, where: i.id == ^id),
      set:
        [
          started_at: plan.started_at,
          finished_at: finished,
          last_event_at: finished,
          duration_ms: duration,
          wall_ms: scale.(inv.wall_ms),
          analysis_ms: scale.(inv.analysis_ms),
          execution_ms: scale.(inv.execution_ms),
          critical_path_ms: scale.(inv.critical_path_ms),
          user_name: plan.user,
          host: plan.host,
          bazel_version: plan.version,
          tags: tags,
          workspace_status: workspace_status,
          workspace: "#{home}/acme",
          cwd: "#{home}/acme",
          local_exec_root: "#{home}/.cache/bazel/execroot/_main"
        ] ++ cache_stats(plan)
    )

    from(t in Target,
      where: t.invocation_id == ^id,
      update: [
        set: [
          first_seen_at: fragment("? + make_interval(secs => ?)", t.first_seen_at, ^wall_secs),
          completed_at: fragment("? + make_interval(secs => ?)", t.completed_at, ^wall_secs)
        ]
      ]
    )
    |> Repo.update_all([])

    from(t in TestResult,
      where: t.invocation_id == ^id,
      update: [set: [started_at: fragment("? + make_interval(secs => ?)", t.started_at, ^secs)]]
    )
    |> Repo.update_all([])

    from(a in Action,
      where: a.invocation_id == ^id,
      update: [
        set: [
          started_at: fragment("? + make_interval(secs => ?)", a.started_at, ^secs),
          ended_at: fragment("? + make_interval(secs => ?)", a.ended_at, ^secs)
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  # Build-level action counters sized like a real repository: CI builds hit a warm remote
  # cache and execute remotely; local builds are smaller and mostly sandboxed. The
  # per-action detail stays the fixture's.
  defp cache_stats(plan) do
    executed = if plan.ci?, do: 200 + :rand.uniform(2_800), else: 20 + :rand.uniform(380)

    hit_rate =
      cond do
        plan.ci? -> 0.6 + :rand.uniform() * 0.35
        :rand.uniform() < 0.4 -> 0.3 + :rand.uniform() * 0.4
        true -> 0.0
      end

    hits = round(executed * hit_rate)
    misses = executed - hits
    remote = if plan.ci?, do: round(misses * 0.8), else: 0
    worker = round((misses - remote) * 0.3)

    [
      actions_created: executed + :rand.uniform(500),
      actions_executed: executed,
      remote_cache_hits: hits,
      remote_exec: remote,
      worker_exec: worker,
      sandbox_exec: misses - remote - worker,
      local_exec: 0
    ]
  end

  # Facets are a cache of the tags column; rebuild them from the truth after reshaping.
  defp rebuild_tag_keys!(project_id) do
    Repo.query!("DELETE FROM tag_keys WHERE project_id = $1", [project_id])

    Repo.query!(
      """
      INSERT INTO tag_keys (project_id, key, value, count, last_seen_at)
      SELECT $1, t.key, t.value, count(*), max(i.started_at)
      FROM invocations i, jsonb_each_text(i.tags) AS t
      WHERE i.project_id = $1
      GROUP BY t.key, t.value
      """,
      [project_id]
    )

    :ok
  end
end
