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
    Conveyor.Invocations.rebuild_tag_keys!(project.id)
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
    Conveyor.Invocations.rebuild_tag_keys!(project.id)
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
      profile_opts: [],
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

    attach_profile!(inv, plan, duration)

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

  @fixture_profile "test/fixtures/blobs/c9fb9e145e0fbb8955f0a0f93e7cfa750e3ab9e6e15387e5caacf811cfa7ec86"
  @mnemonics_weighted [
    {"CppCompile", 40},
    {"Javac", 12},
    {"GoCompile", 10},
    {"TsProject", 8},
    {"CppLink", 5},
    {"Genrule", 8},
    {"TestRunner", 12},
    {"ProtoCompile", 5}
  ]

  # CI builds get a synthetic remote-execution profile (cache checks, input uploads,
  # queueing, remote execution, output downloads per action, spread over worker threads,
  # with phase markers, counters and a critical path); local builds that referenced a
  # profile get the recorded one. Summaries are computed inline so the seed finishes
  # with everything in place.
  defp attach_profile!(inv, plan, duration_ms) do
    cond do
      plan.ci? and inv.status in ["succeeded", "failed"] ->
        put_profile!(
          inv,
          synthetic_profile(duration_ms, Keyword.get(plan[:profile_opts] || [], :actions))
        )

      inv.profile_status == "referenced" and File.exists?(@fixture_profile) ->
        put_profile!(inv, File.read!(@fixture_profile))

      true ->
        :ok
    end
  end

  defp put_profile!(inv, gz) do
    {:ok, blob} = Conveyor.Blobs.put(gz, content_type: "application/gzip", source: "fetch")
    :ok = Conveyor.Artifacts.profile_available(inv, blob)

    Conveyor.Workers.ProfileSummary.perform(%Oban.Job{args: %{"invocation_id" => inv.id}})
    :ok
  end

  @doc "A gzipped Bazel-style JSON profile for a remote-execution build of about `duration_ms`."
  @spec synthetic_profile(pos_integer(), pos_integer() | nil) :: binary()
  def synthetic_profile(duration_ms, actions \\ nil) do
    threads = 8
    actions = actions || max(div(duration_ms, 400), 30)
    total_us = duration_ms * 1000
    analysis_us = div(total_us, 8)

    x = fn tid, cat, name, ts, dur, args ->
      %{
        ph: "X",
        pid: 1,
        tid: tid,
        cat: cat,
        name: name,
        ts: round(ts),
        dur: round(max(dur, 1)),
        args: args
      }
    end

    meta =
      for t <- 0..threads,
          e <- [
            %{
              ph: "M",
              pid: 1,
              tid: t,
              name: "thread_name",
              args: %{name: if(t == 0, do: "Main Thread", else: "skyframe-evaluator #{t}")}
            },
            %{ph: "M", pid: 1, tid: t, name: "thread_sort_index", args: %{sort_index: t}}
          ],
          do: e

    markers =
      for {name, at} <- [
            {"Launch Blaze", 0},
            {"Initialize command", total_us * 0.01},
            {"Evaluate target patterns", total_us * 0.03},
            {"Load and analyze dependencies", total_us * 0.05},
            {"Build artifacts", analysis_us},
            {"Complete build", total_us * 0.99}
          ],
          do: %{
            ph: "i",
            pid: 1,
            tid: 0,
            cat: "build phase marker",
            name: name,
            ts: round(at),
            s: "g"
          }

    exec_us = total_us - analysis_us - div(total_us, 50)
    per_thread = div(actions, threads) + 1

    {events, _} =
      Enum.flat_map_reduce(1..threads, [], fn tid, acc ->
        {evs, _t} =
          Enum.flat_map_reduce(1..per_thread, analysis_us, fn n, t ->
            if t > analysis_us + exec_us,
              do: {[], t},
              else: action_events(x, tid, t, exec_us / per_thread, n)
          end)

        {evs, acc}
      end)

    critical =
      events
      |> Enum.filter(&(&1.cat == "action processing"))
      |> Enum.sort_by(& &1.dur, :desc)
      |> Enum.take(6)
      |> Enum.with_index()
      |> Enum.map(fn {a, _i} ->
        %{
          ph: "X",
          pid: 1,
          tid: threads + 1,
          cat: "critical path component",
          name: "action '#{a.name}'",
          ts: a.ts,
          dur: a.dur,
          args: %{}
        }
      end)

    crit_meta = [
      %{ph: "M", pid: 1, tid: threads + 1, name: "thread_name", args: %{name: "Critical Path"}}
    ]

    counters =
      for k <- 0..div(total_us, 1_000_000) do
        ts = k * 1_000_000

        running =
          Enum.count(
            events,
            &(&1.cat == "action processing" and &1.ts <= ts and &1.ts + &1.dur > ts)
          )

        [
          %{ph: "C", pid: 1, tid: 0, name: "action count", ts: ts, args: %{"action" => running}},
          %{
            ph: "C",
            pid: 1,
            tid: 0,
            name: "CPU usage (Bazel)",
            ts: ts,
            args: %{"cpu" => Float.round(min(running / threads, 1.0) * 3.5, 2)}
          }
        ]
      end

    json = %{
      otherData: %{bazel_version: "release 9.2.0", build_id: Replay.uuid(), synthetic: true},
      traceEvents: meta ++ crit_meta ++ markers ++ events ++ critical ++ List.flatten(counters)
    }

    :zlib.gzip(Jason.encode!(json))
  end

  # One action with its nested phases; returns the events and the next free time.
  defp action_events(x, tid, t, budget_us, n) do
    mnemonic = weighted(@mnemonics_weighted)
    target = "//#{Enum.random(@dirs)}:#{Enum.random(~w(server client core net lib proto))}_#{n}"
    hit? = :rand.uniform() < 0.65
    dur = budget_us * (0.3 + :rand.uniform() * 1.4) * if(hit?, do: 0.15, else: 1.0)
    check = min(dur * (0.05 + :rand.uniform() * 0.1), 200_000)
    args = %{target: target, mnemonic: mnemonic}

    inner =
      if hit? do
        [
          x.(tid, "remote action cache check", "check cache hit", t, check, %{}),
          x.(
            tid,
            "remote output download",
            "download outputs",
            t + check,
            dur - check - 1000,
            %{}
          )
        ]
      else
        upload = dur * (0.03 + :rand.uniform() * 0.12)
        queue = dur * (0.02 + :rand.uniform() * 0.2)
        download = dur * (0.03 + :rand.uniform() * 0.1)
        exec = dur - check - upload - queue - download - 1000

        [
          x.(tid, "remote action cache check", "check cache hit", t, check, %{}),
          x.(
            tid,
            "Remote execution upload time",
            "upload missing inputs",
            t + check,
            upload,
            %{}
          ),
          x.(tid, "Remote execution queuing time", "queued", t + check + upload, queue, %{}),
          x.(
            tid,
            "remote action execution",
            "execute remotely",
            t + check + upload + queue,
            exec,
            %{}
          ),
          x.(
            tid,
            "remote output download",
            "download outputs",
            t + check + upload + queue + exec,
            download,
            %{}
          )
        ]
      end

    action = x.(tid, "action processing", "#{mnemonic} #{target}", t, dur, args)
    complete = x.(tid, "complete action execution", "actuallyCompleteAction", t + dur, 800, %{})
    {[action | inner] ++ [complete], t + dur + 1500}
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
end
