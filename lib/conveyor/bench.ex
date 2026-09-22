defmodule Conveyor.Bench do
  @moduledoc """
  The benchmark harness of the speed and capacity plan (PLAN §24 item 0).

  `run/1` is called inside a running Conveyor node (see `mix conveyor.bench`): it resets the
  bench database, drives `mix conveyor.loadgen` as a child OS process against this node,
  and samples both sides while the run lasts. Every change in the plan must move one of the
  four tracked numbers without breaking the oracle:

    * events per second per app vCPU (`:erlang.statistics(:runtime)` and the schedulers'
      own utilization; the VM runs with `+sbwt none` so OS CPU time is real work),
    * events per second per Postgres vCPU (CPU time of every Postgres process, read
      through `ps` for a native cluster; `pg_stat_statements` execution time as the
      hardware-neutral twin),
    * WAL bytes per event (`pg_stat_wal`),
    * RSS per open stream (peak RSS during the run over the concurrent streams).

  Also recorded: ack latency percentiles as the client saw them, storage bytes per build
  per table, HOT update ratio on `invocations`, statements and round trips per writer
  flush, the top statements by total time, fenced commits, and the oracle verdict over
  every generated invocation. Reports are JSON under `bench/results/`.
  """

  require Logger

  alias Conveyor.Repo

  @flush_event [:conveyor, :ingest, :writer, :flush]
  @group_failed_event [:conveyor, :ingest, :writer, :group_failed]
  @fenced_event [:conveyor, :ingest, :fenced]
  @sample_ms 1_000

  @type report :: map()

  @doc """
  Options:

    * `:label` — name of the change under test (file name of the report)
    * `:streams`, `:builds`, `:delay_ms`, `:jitter_ms`, `:duration_s`, `:fixtures` — passed to the generator
    * `:grpc_port` — where this node's BES listener is (default from config)
    * `:reset` — truncate the bench database first (default true)
    * `:verify` — run the persistence oracle on every invocation afterwards (default true)
    * `:results_dir` — where to write the JSON report (default `bench/results`)
    * `:pg_container` — Docker container name when Postgres is not native (CPU from `docker stats`)
    * `:notes` — free text stored with the report
    * `:runner` — how the load is generated: a function of the options returning
      `{report_map, output, exit_status}`; defaults to spawning `mix conveyor.loadgen`
      (tests run `Conveyor.Loadgen.run/1` in-process)
  """
  @spec run(keyword()) :: report()
  def run(opts) do
    label = Keyword.get(opts, :label, "run")
    streams = Keyword.get(opts, :streams, 200)
    if Keyword.get(opts, :reset, true), do: reset!()
    ensure_pg_stat_statements!()
    :ok = wait_for_settle(div(Keyword.get(opts, :settle_timeout_ms, 30_000), 500))

    # The flag belongs to the process that sets it and is cleared when that process exits,
    # so the long-lived runner owns it, not the sampler.
    :erlang.system_flag(:scheduler_wall_time, true)
    telemetry = start_telemetry()
    sampler = start_sampler(opts[:pg_container], Keyword.get(opts, :sample_ms, @sample_ms))
    before = snapshot(opts[:pg_container])
    started = System.monotonic_time(:millisecond)

    runner = Keyword.get(opts, :runner, &spawn_loadgen/1)
    {loadgen, output, status} = runner.(opts)

    elapsed_ms = System.monotonic_time(:millisecond) - started
    # Let the last commits, acks and worker lingers land before the after-snapshot.
    Process.sleep(Keyword.get(opts, :settle_ms, 1_500))
    after_ = snapshot(opts[:pg_container])
    samples = stop_sampler(sampler)
    flushes = stop_telemetry(telemetry)

    verify = if Keyword.get(opts, :verify, true), do: verify(loadgen), else: %{skipped: true}

    report =
      build_report(
        label,
        opts,
        streams,
        elapsed_ms,
        before,
        after_,
        samples,
        flushes,
        loadgen,
        verify,
        output,
        status
      )

    write_report(report, Keyword.get(opts, :results_dir, "bench/results"))
  end

  # --- database reset --------------------------------------------------------------------

  @doc "Empties every build-derived table so runs start from the same size."
  def reset! do
    Repo.query!("TRUNCATE invocations CASCADE")
    Repo.query!("TRUNCATE event_segments, log_segments, tag_keys, blobs CASCADE")
    Repo.query!("TRUNCATE oban_jobs")
    # VACUUM cannot run inside a transaction, and the test sandbox wraps everything in one.
    unless Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: Repo.query!("VACUUM ANALYZE invocations")

    Repo.query!("SELECT pg_stat_reset()")
    :ok
  end

  # The extension needs `shared_preload_libraries`; without it statements are not attributed.
  defp ensure_pg_stat_statements! do
    if pg_stat_statements?() do
      Repo.query!("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
      Repo.query!("SELECT pg_stat_statements_reset()")
    else
      Logger.warning("pg_stat_statements is not preloaded: no per-statement attribution")
    end

    :ok
  end

  defp pg_stat_statements? do
    %{rows: [[libs]]} = Repo.query!("SHOW shared_preload_libraries")
    String.contains?(libs, "pg_stat_statements")
  end

  # Postgres runs on this host when its data directory is visible here; only then do the
  # pids in pg_stat_activity mean anything to `ps`.
  defp pg_native? do
    %{rows: [[dir]]} = Repo.query!("SHOW data_directory")
    File.dir?(dir)
  end

  # Wait for previous workers to linger out so the stream count starts from zero.
  defp wait_for_settle(tries) do
    case {live_streams(), tries} do
      {0, _} -> :ok
      {_, 0} -> :ok
      _ -> Process.sleep(500) && wait_for_settle(tries - 1)
    end
  end

  defp live_streams, do: Registry.count(Conveyor.Ingest.Registry)

  # Open BES streams; workers linger after a build, so they are counted separately.
  defp open_streams, do: Conveyor.Limits.total_streams()

  # --- load generator as a child process -----------------------------------------------

  @doc false
  def spawn_loadgen(opts) do
    report_path = Path.join(System.tmp_dir!(), "conveyor-bench-#{System.os_time(:second)}.json")

    # The child must not start a server of its own, and its VM must not spin.
    env = [{"PHX_SERVER", "false"}, {"ERL_FLAGS", "+sbwt none +sbwtdcpu none +sbwtdio none"}]

    {output, status} =
      System.cmd("mix", loadgen_args(opts, report_path), env: env, stderr_to_stdout: true)

    {read_loadgen_report(report_path, output, status), output, status}
  end

  @doc false
  def loadgen_args(opts, report_path) do
    grpc_port =
      Keyword.get(opts, :grpc_port) || Application.get_env(:conveyor, Conveyor.Grpc)[:port]

    [
      "conveyor.loadgen",
      "--hosts",
      "localhost:#{grpc_port}",
      "--streams",
      to_string(Keyword.get(opts, :streams, 200)),
      "--report",
      report_path
    ] ++
      opt_arg(opts, :builds, "--builds") ++
      opt_arg(opts, :delay_ms, "--delay-ms") ++
      opt_arg(opts, :jitter_ms, "--jitter-ms") ++
      opt_arg(opts, :duration_s, "--duration-s") ++
      opt_arg(opts, :fixtures, "--fixtures") ++
      opt_arg(opts, :drop_after, "--drop-after") ++
      opt_arg(opts, :api_key, "--api-key")
  end

  @doc false
  def read_loadgen_report(report_path, output, status) do
    case File.read(report_path) do
      {:ok, json} -> Jason.decode!(json)
      _ -> %{"error" => "no report", "output" => output, "status" => status}
    end
  end

  defp opt_arg(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> []
      v -> [flag, to_string(v)]
    end
  end

  # --- sampling --------------------------------------------------------------------------

  defp start_sampler(pg_container, sample_ms) do
    parent = self()
    postmaster = if pg_container == nil and pg_native?(), do: postmaster_pid()

    spawn_link(fn ->
      sample_loop(parent, pg_container, sample_ms, %{
        rss: [],
        beam_total: [],
        pg_cpu_pct: [],
        streams: [],
        workers: [],
        postmaster: postmaster,
        # pid => {first seen cpu seconds, last seen}; Postgres forks and reaps workers
        # (autovacuum, parallel query) during a run, so every process is tracked from the
        # moment it is seen.
        pg_procs: pg_process_times(postmaster, %{}),
        reductions: reductions_by_kind(),
        # process memory by kind at the sample with the most memory in use
        memory_peak: {0, []},
        cpu: cpu_sample()
      })
    end)
  end

  defp sample_loop(parent, pg_container, sample_ms, acc) do
    receive do
      {:stop, ref} ->
        send(parent, {ref, acc})
    after
      sample_ms ->
        acc = %{
          acc
          | rss: [os_rss() | acc.rss],
            beam_total: [:erlang.memory(:total) | acc.beam_total],
            pg_cpu_pct: [docker_cpu_pct(pg_container) | acc.pg_cpu_pct],
            streams: [open_streams() | acc.streams],
            workers: [live_streams() | acc.workers],
            pg_procs: pg_process_times(acc.postmaster, acc.pg_procs),
            memory_peak: memory_peak(acc.memory_peak)
        }

        sample_loop(parent, pg_container, sample_ms, acc)
    end
  end

  defp stop_sampler(pid) do
    ref = make_ref()
    send(pid, {:stop, ref})

    receive do
      {^ref, acc} ->
        acc
        |> Map.put(:cpu_end, cpu_sample())
        |> Map.put(:reductions_end, reductions_by_kind())
        |> Map.update!(:pg_procs, &pg_process_times(acc.postmaster, &1))
    after
      5_000 ->
        %{
          rss: [],
          beam_total: [],
          pg_cpu_pct: [],
          streams: [],
          workers: [],
          pg_procs: %{},
          reductions: %{},
          reductions_end: %{},
          memory_peak: {0, []},
          cpu: nil,
          cpu_end: nil
        }
    end
  end

  # Process memory by kind, kept for the sample where processes hold the most in total.
  defp memory_peak({best, _} = current) do
    total = :erlang.memory(:processes_used)

    if total > best do
      by_kind =
        Process.list()
        |> Enum.reduce(%{}, fn pid, acc ->
          case Process.info(pid, [:memory, :registered_name, :dictionary, :initial_call]) do
            nil -> acc
            info -> Map.update(acc, process_kind(info), info[:memory], &(&1 + info[:memory]))
          end
        end)
        |> Enum.sort_by(fn {_, n} -> -n end)
        |> Enum.take(12)
        |> Enum.map(fn {kind, n} -> %{kind: kind, bytes: n} end)

      {total, by_kind}
    else
      current
    end
  end

  # Reductions per kind of process (the registered name, `$initial_call` or initial call):
  # the BEAM's own unit of work, to see where the node's CPU goes. Processes that exit
  # between the samples are not counted; finished workers linger long enough to be seen.
  @doc false
  def reductions_by_kind do
    Process.list()
    |> Enum.reduce(%{}, fn pid, acc ->
      case Process.info(pid, [:reductions, :registered_name, :dictionary, :initial_call]) do
        nil -> acc
        info -> Map.update(acc, process_kind(info), info[:reductions], &(&1 + info[:reductions]))
      end
    end)
  end

  defp process_kind(info) do
    case {info[:registered_name], info[:dictionary][:"$initial_call"], info[:initial_call]} do
      {name, _, _} when is_atom(name) and name != nil -> inspect(name)
      {_, {m, f, a}, _} -> Exception.format_mfa(m, f, a)
      {_, _, {m, f, a}} -> Exception.format_mfa(m, f, a)
      _ -> "unknown"
    end
  end

  defp reductions_delta(%{reductions: r0, reductions_end: r1}) do
    r1
    |> Enum.map(fn {kind, n} -> {kind, n - Map.get(r0, kind, 0)} end)
    |> Enum.filter(fn {_, n} -> n > 0 end)
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(15)
    |> Enum.map(fn {kind, n} -> %{kind: kind, reductions: n} end)
  end

  defp reductions_delta(_), do: []

  # --- Postgres process CPU (native cluster) -----------------------------------------------

  defp postmaster_pid do
    %{rows: [[dir]]} = Repo.query!("SHOW data_directory")

    case File.read(Path.join(dir, "postmaster.pid")) do
      {:ok, content} -> content |> String.split("\n") |> hd() |> String.trim()
      _ -> nil
    end
  end

  # `ps` for the postmaster and its children; each pid keeps {first, last} CPU seconds.
  @doc false
  def pg_process_times(nil, acc), do: acc

  def pg_process_times(postmaster, acc) do
    case System.cmd("ps", ["-axo", "pid=,ppid=,time="]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reduce(acc, fn line, acc ->
          case String.split(line) do
            [pid, ppid, time] when pid == postmaster or ppid == postmaster ->
              secs = parse_cpu_time(time)
              Map.update(acc, pid, {secs, secs}, fn {first, _} -> {first, secs} end)

            _ ->
              acc
          end
        end)

      _ ->
        acc
    end
  rescue
    _ -> acc
  end

  # CPU seconds per backend type; pids gone by the end of the run (autovacuum workers,
  # parallel workers) are grouped as "exited".
  defp pg_cpu_by_backend(procs) when map_size(procs) == 0, do: %{}

  defp pg_cpu_by_backend(procs) do
    %{rows: rows} =
      Repo.query!("SELECT pid::text, backend_type FROM pg_stat_activity WHERE pid IS NOT NULL")

    types = Map.new(rows, fn [pid, type] -> {pid, type} end)

    procs
    |> Enum.reduce(%{}, fn {pid, {first, last}}, acc ->
      Map.update(acc, Map.get(types, pid, "exited"), last - first, &(&1 + (last - first)))
    end)
    |> Map.new(fn {k, v} -> {k, Float.round(v, 2)} end)
  end

  defp pg_cpu_from_procs(procs) when map_size(procs) == 0, do: nil

  defp pg_cpu_from_procs(procs) do
    procs
    |> Enum.map(fn {_pid, {first, last}} -> last - first end)
    |> Enum.sum()
    |> Float.round(2)
  end

  # Scheduler utilization and emulator CPU time (`+sbwt none` keeps both honest). The
  # wall-time counters are read raw: busy schedulers = Σ active / Σ total over the normal
  # and dirty-CPU schedulers, which cannot go negative when the flag is toggled elsewhere.
  defp cpu_sample do
    {runtime_ms, _} = :erlang.statistics(:runtime)
    {wall_ms, _} = :erlang.statistics(:wall_clock)
    %{runtime_ms: runtime_ms, wall_ms: wall_ms, sched: scheduler_counters()}
  end

  defp scheduler_counters do
    normal = System.schedulers_online()
    dirty_cpu = :erlang.system_info(:dirty_cpu_schedulers_online)

    :erlang.statistics(:scheduler_wall_time_all)
    |> Enum.filter(fn {id, _active, _total} -> id <= normal + dirty_cpu end)
    |> Enum.map(fn {id, active, total} -> {id, {active, total}} end)
    |> Map.new()
  end

  defp app_cpu(%{cpu: nil}), do: %{}

  defp app_cpu(%{cpu: s0, cpu_end: s1}) do
    wall_s = max(s1.wall_ms - s0.wall_ms, 1) / 1000

    busy =
      s1.sched
      |> Enum.map(fn {id, {active1, total1}} ->
        {active0, total0} = Map.get(s0.sched, id, {0, 0})
        if total1 > total0, do: (active1 - active0) / (total1 - total0), else: 0.0
      end)
      |> Enum.sum()

    %{
      wall_s: Float.round(wall_s, 1),
      runtime_vcpu: Float.round((s1.runtime_ms - s0.runtime_ms) / 1000 / wall_s, 2),
      scheduler_vcpu: Float.round(busy, 2),
      schedulers_online: System.schedulers_online()
    }
  end

  defp os_rss do
    case System.cmd("ps", ["-o", "rss=", "-p", System.pid()]) do
      {out, 0} -> out |> String.trim() |> String.to_integer() |> Kernel.*(1024)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc false
  def docker_cpu_pct(nil), do: nil

  def docker_cpu_pct(container) do
    case System.cmd("docker", ["stats", "--no-stream", "--format", "{{.CPUPerc}}", container]) do
      {out, 0} ->
        out |> String.trim() |> String.trim_trailing("%") |> Float.parse() |> elem(0)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # --- Postgres snapshots ------------------------------------------------------------------

  defp snapshot(_pg_container) do
    %{
      wal: one_row("SELECT wal_records, wal_fpi, wal_bytes::bigint FROM pg_stat_wal"),
      db:
        one_row("""
        SELECT xact_commit, xact_rollback, blks_read, blks_hit, tup_inserted, tup_updated,
               pg_database_size(current_database())::bigint AS size
        FROM pg_stat_database WHERE datname = current_database()
        """),
      invocations:
        one_row("""
        SELECT n_tup_ins, n_tup_upd, n_tup_hot_upd, n_dead_tup, seq_scan, idx_scan
        FROM pg_stat_user_tables WHERE relname = 'invocations'
        """),
      tables: table_sizes(),
      tuples: table_tuples(),
      statements: if(pg_stat_statements?(), do: statements(), else: [])
    }
  end

  defp one_row(sql) do
    %{columns: cols, rows: [row]} = Repo.query!(sql)
    cols |> Enum.zip(row) |> Map.new(fn {k, v} -> {k, v} end)
  end

  @tables ~w(invocations event_segments log_segments targets test_results actions named_sets invocation_metrics tag_keys)

  defp table_sizes do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT parent.relname, SUM(pg_total_relation_size(child.oid))::bigint
        FROM pg_class parent
        LEFT JOIN pg_inherits i ON i.inhparent = parent.oid
        LEFT JOIN pg_class child ON child.oid = COALESCE(i.inhrelid, parent.oid)
        WHERE parent.relname = ANY($1) AND parent.relnamespace = 'public'::regnamespace
        GROUP BY parent.relname
        """,
        [@tables]
      )

    Map.new(rows, fn [name, size] -> {name, size} end)
  end

  # Inserted/updated/live tuples per table: inserts of rolled-back transactions still count
  # in n_tup_ins, so a gap between inserted and live rows exposes redone work.
  defp table_tuples do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT relname, n_tup_ins, n_tup_upd, n_tup_hot_upd, n_tup_del, n_live_tup, n_dead_tup
        FROM pg_stat_user_tables WHERE relname = ANY($1)
        """,
        [@tables]
      )

    Map.new(rows, fn [name | counts] ->
      {name, Enum.zip(~w(ins upd hot_upd del live dead)a, counts) |> Map.new()}
    end)
  end

  @doc false
  def cpu_seconds_of(pids) do
    case System.cmd("ps", ["-o", "time=", "-p", Enum.join(pids, ",")]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_cpu_time/1)
        |> Enum.sum()
        |> Float.round(2)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc false
  # `ps -o time` prints [[dd-]hh:]mm:ss[.cc]
  def parse_cpu_time(text) do
    text = String.trim(text)

    {days, rest} =
      case String.split(text, "-") do
        [d, r] -> {String.to_integer(d), r}
        [r] -> {0, r}
      end

    parts = rest |> String.split(":") |> Enum.map(&parse_float/1)

    seconds =
      case parts do
        [h, m, s] -> h * 3600 + m * 60 + s
        [m, s] -> m * 60 + s
        [s] -> s
      end

    days * 86_400 + seconds
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp statements do
    %{rows: rows} =
      Repo.query!("""
      SELECT calls, total_exec_time, rows, shared_blks_dirtied, wal_bytes::bigint, toplevel,
             left(query, 160), total_plan_time
      FROM pg_stat_statements
      WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      ORDER BY total_exec_time DESC
      """)

    statement_rows(rows)
  end

  @doc false
  def statement_rows(rows) do
    Enum.map(rows, fn [calls, time, nrows, dirtied, wal, top, q | rest] ->
      %{
        calls: calls,
        ms: time,
        plan_ms: List.first(rest) || 0.0,
        rows: nrows,
        dirtied: dirtied,
        wal: wal,
        toplevel: top,
        query: q
      }
    end)
  end

  # --- writer telemetry --------------------------------------------------------------------

  defp start_telemetry do
    table = :ets.new(:conveyor_bench, [:public, :duplicate_bag])
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [@flush_event, @fenced_event, @group_failed_event],
      fn
        @flush_event, %{duration: d, batches: b, events: e}, _meta, table ->
          :ets.insert(table, {:flush, System.convert_time_unit(d, :native, :microsecond), b, e})

        @fenced_event, _m, _meta, table ->
          :ets.insert(table, {:fenced, 1})

        @group_failed_event, _m, %{reason: reason}, table ->
          :ets.insert(table, {:group_failed, String.slice(reason, 0, 200)})
      end,
      table
    )

    {id, table}
  end

  defp stop_telemetry({id, table}) do
    :telemetry.detach(id)
    flushes = :ets.match_object(table, {:flush, :_, :_, :_})
    fenced = length(:ets.match_object(table, {:fenced, :_}))
    group_failures = :ets.match_object(table, {:group_failed, :_}) |> Enum.map(&elem(&1, 1))
    :ets.delete(table)

    durations = flushes |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    n = length(flushes)

    %{
      count: n,
      batches: Enum.sum(Enum.map(flushes, &elem(&1, 2))),
      events: Enum.sum(Enum.map(flushes, &elem(&1, 3))),
      batches_per_flush: ratio(Enum.sum(Enum.map(flushes, &elem(&1, 2))), n),
      events_per_flush: ratio(Enum.sum(Enum.map(flushes, &elem(&1, 3))), n),
      duration_ms: durations |> Enum.map(&(&1 / 1000)) |> percentiles(),
      fenced: fenced,
      group_failures: length(group_failures),
      group_failure_reasons: group_failures |> Enum.frequencies() |> Enum.take(5)
    }
  end

  # --- oracle ----------------------------------------------------------------------------

  defp verify(%{"invocations" => invocations}) do
    failures =
      invocations
      |> Task.async_stream(
        fn %{"id" => id, "sent" => sent} ->
          # The final component_stream_finished marker is acked but not stored as an event.
          case Conveyor.Ingest.Verify.check(id, sent - 1) do
            :ok -> nil
            {:error, problems} -> %{id: id, problems: inspect(problems)}
          end
        end,
        max_concurrency: 8,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, nil} -> []
        {:ok, f} -> [f]
      end)

    leftovers =
      Repo.query!("SELECT count(*) FROM invocations WHERE status = 'in_progress'").rows
      |> hd()
      |> hd()

    %{
      checked: length(invocations),
      failed: length(failures),
      failures: Enum.take(failures, 10),
      in_progress_left: leftovers
    }
  end

  defp verify(_), do: %{checked: 0, failed: 0, failures: [], error: "no invocation list"}

  # --- report ------------------------------------------------------------------------------

  defp build_report(
         label,
         opts,
         streams,
         elapsed_ms,
         b,
         a,
         samples,
         flushes,
         loadgen,
         verify,
         output,
         status
       ) do
    events = loadgen["events"] || 0
    builds = loadgen["builds_ok"] || 0
    wall_s = max(elapsed_ms, 1) / 1000
    cpu = app_cpu(samples)

    pg_cpu_s =
      case {pg_cpu_from_procs(samples[:pg_procs] || %{}), samples.pg_cpu_pct} do
        {secs, _} when is_number(secs) ->
          secs

        {_, pcts} when pcts != [] ->
          pcts
          |> Enum.reject(&is_nil/1)
          |> mean()
          |> Kernel./(100)
          |> Kernel.*(wall_s)
          |> Float.round(2)

        _ ->
          nil
      end

    pg_exec_s = (sum_field(a.statements, :ms) - sum_field(b.statements, :ms)) / 1000
    pg_plan_s = (sum_field(a.statements, :plan_ms) - sum_field(b.statements, :plan_ms)) / 1000
    wal_bytes = a.wal["wal_bytes"] - b.wal["wal_bytes"]
    xacts = a.db["xact_commit"] - b.db["xact_commit"]
    upd = a.invocations["n_tup_upd"] - b.invocations["n_tup_upd"]
    hot = a.invocations["n_tup_hot_upd"] - b.invocations["n_tup_hot_upd"]
    calls = sum_field(a.statements, :calls) - sum_field(b.statements, :calls)
    # Round trips are the top-level statements; nested ones are foreign-key checks and the like.
    top_calls =
      sum_field(toplevel(a.statements), :calls) - sum_field(toplevel(b.statements), :calls)

    baseline_rss = samples.rss |> Enum.reverse() |> List.first() || 0
    peak_rss = Enum.max(samples.rss, fn -> 0 end)
    peak_streams = Enum.max(samples.streams, fn -> 0 end)
    peak_streams = if peak_streams > 0, do: peak_streams, else: streams
    peak_workers = Enum.max(samples.workers, fn -> 0 end)

    %{
      label: label,
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      git: git_rev(),
      notes: Keyword.get(opts, :notes),
      machine: machine(),
      settings: %{
        streams: streams,
        builds: Keyword.get(opts, :builds),
        delay_ms: Keyword.get(opts, :delay_ms, 0),
        duration_s: Keyword.get(opts, :duration_s),
        ingest: Application.get_env(:conveyor, Conveyor.Ingest) |> Map.new(),
        pool_size: Repo.config()[:pool_size]
      },
      # The four numbers of PLAN §24 item 0 come first.
      headline: %{
        events_per_s: Float.round(events / wall_s, 1),
        events_per_s_per_app_vcpu: per_vcpu(events, wall_s, cpu[:runtime_vcpu]),
        events_per_s_per_pg_vcpu:
          if(pg_cpu_s && pg_cpu_s > 0, do: Float.round(events / pg_cpu_s, 1)),
        events_per_pg_exec_s: if(pg_exec_s > 0, do: Float.round(events / pg_exec_s, 1)),
        wal_bytes_per_event: ratio(wal_bytes, events),
        rss_bytes_per_stream: ratio(peak_rss - baseline_rss, peak_streams),
        ack_p50_ms: get_in(loadgen, ["ack_latency_ms", "p50"]),
        ack_p99_ms: get_in(loadgen, ["ack_latency_ms", "p99"]),
        storage_bytes_per_build: ratio(a.db["size"] - b.db["size"], builds)
      },
      loadgen:
        Map.drop(loadgen, ["invocations", "failures"])
        |> Map.put("failures", Enum.take(loadgen["failures"] || [], 5)),
      app:
        Map.merge(cpu, %{
          rss_baseline: baseline_rss,
          rss_peak: peak_rss,
          beam_peak: Enum.max(samples.beam_total, fn -> 0 end),
          peak_streams: peak_streams,
          peak_workers: peak_workers,
          reductions_by_kind: reductions_delta(samples),
          processes_peak_bytes: samples[:memory_peak] |> elem(0),
          memory_by_kind: samples[:memory_peak] |> elem(1)
        }),
      postgres: %{
        cpu_s: pg_cpu_s,
        exec_s: Float.round(pg_exec_s, 2),
        plan_s: Float.round(pg_plan_s, 2),
        cpu_by_backend: pg_cpu_by_backend(samples[:pg_procs] || %{}),
        vcpu: if(pg_cpu_s, do: Float.round(pg_cpu_s / wall_s, 2)),
        xacts: xacts,
        xacts_per_s: Float.round(xacts / wall_s, 1),
        statements: calls,
        round_trips: top_calls,
        nested_statements: calls - top_calls,
        round_trips_per_flush: ratio(top_calls, flushes.count),
        round_trips_per_xact: ratio(top_calls, xacts),
        wal_bytes: wal_bytes,
        wal_fpi: a.wal["wal_fpi"] - b.wal["wal_fpi"],
        wal_records: a.wal["wal_records"] - b.wal["wal_records"],
        invocations_upd: upd,
        invocations_hot_pct: if(upd > 0, do: Float.round(hot * 100 / upd, 1)),
        size_delta: a.db["size"] - b.db["size"],
        rollbacks: a.db["xact_rollback"] - b.db["xact_rollback"],
        tables: Map.new(a.tables, fn {t, s} -> {t, s - (b.tables[t] || 0)} end),
        tuples:
          Map.new(a.tuples, fn {t, counts} ->
            {t, Map.new(counts, fn {k, v} -> {k, v - get_in(b.tuples, [t, k])} end)}
          end),
        top_statements:
          a.statements
          |> Enum.take(12)
          |> Enum.map(fn st ->
            st
            |> Map.update!(:ms, &Float.round(&1, 1))
            |> Map.update!(:plan_ms, &Float.round(&1, 1))
          end)
      },
      writer: flushes,
      verify: verify,
      loadgen_exit: status,
      loadgen_output_tail: output |> String.split("\n") |> Enum.take(-12) |> Enum.join("\n")
    }
  end

  defp per_vcpu(_events, _wall, nil), do: nil
  defp per_vcpu(_events, _wall, vcpu) when vcpu <= 0, do: nil
  defp per_vcpu(events, wall_s, vcpu), do: Float.round(events / wall_s / vcpu, 1)

  defp ratio(_num, 0), do: nil
  defp ratio(_num, nil), do: nil
  defp ratio(num, den), do: Float.round(num / den, 1)

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)

  defp sum_field(statements, field),
    do: statements |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()

  defp toplevel(statements), do: Enum.filter(statements, & &1.toplevel)

  defp percentiles([]), do: %{p50: nil, p99: nil, max: nil}

  defp percentiles(sorted) do
    n = length(sorted)
    at = fn q -> sorted |> Enum.at(min(trunc(q * n), n - 1)) |> Float.round(1) end
    %{p50: at.(0.5), p99: at.(0.99), max: sorted |> List.last() |> Float.round(1)}
  end

  defp git_rev do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp machine do
    %{
      os: :erlang.system_info(:system_architecture) |> to_string(),
      schedulers: System.schedulers_online(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      postgres: Repo.query!("SHOW server_version").rows |> hd() |> hd()
    }
  end

  defp write_report(report, dir) do
    File.mkdir_p!(dir)

    stamp =
      report.at
      |> String.replace(~r/[-:]/, "")
      |> String.replace("T", "-")
      |> String.trim_trailing("Z")

    path = Path.join(dir, "#{stamp}-#{report.label}.json")
    File.write!(path, Jason.encode!(report, pretty: true))
    Map.put(report, :path, path)
  end

  @profiles %{
    # 200 builds at once replayed flat out: the Postgres-bound shape.
    "flatout" => [streams: 200, builds: 10_000],
    # 1,000 builds at once paced like real ones: the memory-per-stream shape.
    "paced" => [streams: 1_000, builds: 1_500, delay_ms: 500]
  }

  @doc "Generator settings of a named profile (`flatout`, `paced`), overridden by `opts`."
  def profile_opts(name, opts), do: Keyword.merge(Map.get(@profiles, name || "flatout", []), opts)

  @doc "Medians of the headline numbers across repeated runs (laptop noise is about ±20 %)."
  def summarize_repeats(reports) do
    keys = reports |> hd() |> Map.fetch!(:headline) |> Map.keys() |> Enum.sort()

    lines =
      for k <- keys do
        values =
          reports |> Enum.map(&Map.get(&1.headline, k)) |> Enum.reject(&is_nil/1) |> Enum.sort()

        "  #{String.pad_trailing(to_string(k), 28)} #{median(values)}   #{inspect(values)}"
      end

    "median of #{length(reports)} runs\n" <> Enum.join(lines, "\n") <> "\n"
  end

  @doc false
  def median([]), do: nil

  def median(sorted) do
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: Float.round((Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2, 1)
  end

  @doc "True when the run met every correctness check: oracle, acks, builds."
  def correct?(r) do
    r.verify[:failed] in [0, nil] and (r.loadgen["missing_acks"] || 0) == 0 and
      (r.loadgen["builds_failed"] || 0) == 0
  end

  defp tuple_summary(tuples) do
    tuples
    |> Enum.sort()
    |> Enum.map_join(", ", fn {t, c} -> "#{t} #{c.ins} ins/#{c.live} live" end)
  end

  @doc "One-screen summary of a report."
  def format(r) do
    h = r.headline
    p = r.postgres
    w = r.writer
    v = r.verify

    """
    #{r.label} (#{r.git}) #{r.settings.streams} streams, #{r.loadgen["builds_ok"]}/#{r.loadgen["builds_total"]} builds, #{r.loadgen["events"]} events in #{r.app[:wall_s]} s
      events/s            #{h.events_per_s}
      per app vCPU        #{h.events_per_s_per_app_vcpu}   (app #{r.app[:runtime_vcpu]} vCPU by OS time; #{r.app[:scheduler_vcpu]} schedulers active, wall-clock, inflates under core contention)
      per Postgres vCPU   #{h.events_per_s_per_pg_vcpu}   (pg #{p.vcpu} vCPU: #{inspect(p.cpu_by_backend)}; exec #{p.exec_s} s, plan #{p.plan_s} s)
      WAL bytes/event     #{h.wal_bytes_per_event}   (#{p.wal_bytes} bytes, #{p.wal_fpi} full-page images)
      RSS/stream          #{h.rss_bytes_per_stream}   (peak #{r.app[:rss_peak]} over #{r.app[:peak_streams]} streams, #{r.app[:peak_workers]} workers)
      storage/build       #{h.storage_bytes_per_build}
      ack ms              p50 #{h.ack_p50_ms}  p99 #{h.ack_p99_ms}
      postgres            #{p.xacts_per_s} xact/s, #{p.round_trips} round trips (#{p.round_trips_per_flush}/flush, #{p.round_trips_per_xact}/xact) + #{p.nested_statements} nested, HOT #{p.invocations_hot_pct} %
      writer              #{w.count} flushes, #{w.batches_per_flush} batches/flush, #{w.events_per_flush} events/flush, flush ms p50 #{w.duration_ms.p50} p99 #{w.duration_ms.p99}, fenced #{w.fenced}, group failures #{w.group_failures}, rollbacks #{p.rollbacks}
      tuples              #{tuple_summary(p.tuples)}
      verify              #{v[:checked]} checked, #{v[:failed]} failed, #{v[:in_progress_left]} left in_progress, missing acks #{r.loadgen["missing_acks"]}
      reductions          #{r.app[:reductions_by_kind] |> Enum.take(6) |> Enum.map_join(", ", &"#{&1.kind} #{div(&1.reductions, 1_000_000)}M")}
      memory              #{r.app[:memory_by_kind] |> Enum.take(6) |> Enum.map_join(", ", &"#{&1.kind} #{div(&1.bytes, 1_000_000)} MB")} (processes #{div(r.app[:processes_peak_bytes] || 0, 1_000_000)} MB)
      report              #{r[:path]}
    """
  end
end
