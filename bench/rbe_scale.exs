# The 360-project case of the RBE opportunity analysis, measured (PLAN §27.9).
#
# Run through bench/rbe_scale.sh, which starts the bench Postgres and one or two prod-mode
# nodes and then this driver:
#
#   bench/rbe_scale.sh --label first [--nodes 2] [--projects 360] [--builds 2000]
#
# The model (a Go monorepo, one Conveyor project per app, one cache group, a cache per
# machine, Bazel action digests in the log):
#
#   * A pool of SHARED library actions; each app uses a popularity-weighted subset of it
#     for SHARE_MIN..SHARE_MAX of its spawns and has app-specific actions for the rest.
#     A build's log has SPAWNS_MIN..SPAWNS_MAX spawns (log-uniform): GoStdlib,
#     GoCompilePkg, GoLink, TestRunner.
#   * Builds come in waves (a commit fans out to a set of apps that start within 90 s of
#     each other, so apps race on what the commit changed); a commit changes 1 % of the
#     shared actions and 10 % of the app-specific actions of the apps it builds.
#   * A build runs on a new machine (35 %) or on one of the 60 most recent ones; an action
#     the machine has already run is a cache hit, everything else executes on 16 lanes.
#   * Half of the tests state `cores=2` in an exec property; 1 % of them may not be cached.
#
# Builds are inserted as rows (event-stream ingest is measured by `mix conveyor.bench`);
# every log is uploaded with `PUT /api/v1/invocations/:id/artifacts/execution.log.zst` and
# parsed by the nodes' Oban `parse` queue at its configured concurrency.
#
# The generator classes every execution by brute force (first by finish per key in the
# group; racing or sequential against it; within the project or across projects) and the
# driver compares counts, wall ms and core ms with the group's and five projects' JSON.
Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Conveyor.Repo.start_link(pool_size: 10)

defmodule RbeScale do
  alias Conveyor.ExecLog.Synth
  alias Conveyor.Invocations.Invocation
  alias Conveyor.{Projects, Repo}
  alias Conveyor.Rbe.Groups

  @group "rbe-scale"
  @lanes 16

  def env(name, default), do: String.to_integer(System.get_env(name, to_string(default)))

  # --- setup -----------------------------------------------------------------------------------

  def projects(n) do
    for i <- 1..n do
      slug = "app-#{String.pad_leading(Integer.to_string(i), 3, "0")}"

      project =
        Projects.get_project_by_slug(slug) ||
          elem(Projects.create_project(%{slug: slug, name: "App #{i}"}), 1)

      {:ok, project} = Groups.put(project, @group)
      {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "bench", scopes: ["upload"]})
      %{id: project.id, slug: slug, key: plaintext, index: i}
    end
  end

  # --- the model -------------------------------------------------------------------------------

  def log_uniform(min, max), do: round(min * :math.pow(max / min, :rand.uniform()))

  # The actions of an app: {kind, id} with kind :shared | {:app, index}.
  def app_actions(index, shared_pool, opts) do
    spawns = log_uniform(opts.spawns_min, opts.spawns_max)
    share = opts.share_min + :rand.uniform() * (opts.share_max - opts.share_min)

    shared =
      Stream.repeatedly(fn -> ceil(shared_pool * :math.pow(:rand.uniform(), 2)) end)
      |> Stream.uniq()
      |> Enum.take(min(round(spawns * share), shared_pool))
      # the standard library first, as Bazel builds it
      |> then(&Enum.uniq([1 | &1]))
      |> Enum.map(&{:shared, &1})

    own = for n <- 1..max(spawns - length(shared), 1), do: {{:app, index}, n}
    shared ++ own
  end

  def mnemonic({:shared, 1}), do: "GoStdlib"
  def mnemonic({:shared, _}), do: "GoCompilePkg"

  def mnemonic({{:app, _}, n}) do
    cond do
      rem(n, 40) == 0 -> "GoLink"
      rem(n, 12) == 0 -> "TestRunner"
      true -> "GoCompilePkg"
    end
  end

  # Milliseconds an execution of the action takes (per action, the same on every machine
  # up to 20 % noise).
  def duration(action, mnemonic) do
    base = :erlang.phash2({:d, action}, 1000) / 1000

    median =
      case mnemonic do
        "GoStdlib" -> 45_000
        "GoCompilePkg" -> 1_200
        "GoLink" -> 4_000
        "TestRunner" -> 9_000
      end

    round(median * :math.exp((base - 0.5) * 1.6) * (0.9 + :rand.uniform() * 0.2)) |> max(20)
  end

  def target({:shared, 1}), do: "@io_bazel_rules_go//:stdlib"
  def target({:shared, n}), do: "//go/lib/pkg#{div(n, 20)}/sub#{rem(n, 20)}:sub#{rem(n, 20)}"
  def target({{:app, a}, n}), do: "//go/apps/app#{a}/internal/pkg#{n}:pkg#{n}"

  # The spawn of an action at a version, as the log has it. Inputs: the sources of the
  # package and the archives it imports (6 to 24 files).
  def entry(action, version, mnemonic) do
    identity = :erlang.term_to_binary({action, version})
    seed = :erlang.phash2(action, 1_000_000)
    target = target(action)
    package = target |> String.trim_leading("/") |> String.replace(~r/[@:]/, "/")

    inputs =
      for i <- 1..(6 + rem(seed, 19)) do
        if i <= 4,
          do: {"#{package}/file#{i}.go", Synth.hash([identity, <<i>>])},
          else: {"bazel-out/k8-fastbuild/bin/go/lib/dep#{rem(seed * i, 4000)}.a", Synth.hash(<<seed * i::64>>)}
      end

    {cores_milli, cacheable} = traits(action, mnemonic)

    %{
      mnemonic: mnemonic,
      target: target,
      args: ["bazel-out/host/bin/builder", String.downcase(mnemonic), "-o", "bazel-out/k8-fastbuild/bin/#{package}.a"],
      inputs: inputs,
      output: {"bazel-out/k8-fastbuild/bin/#{package}.a", Synth.hash([identity, "out"])},
      digest: Synth.hash(identity),
      platform: if(cores_milli == 2000, do: %{"cores" => "2", "OSFamily" => "linux"}),
      cacheable: cacheable
    }
  end

  # {cores in thousandths, cacheable}: half of the tests state two cores, 1 % of them
  # may not be cached.
  def traits(action, mnemonic) do
    seed = :erlang.phash2(action, 1_000_000)
    test? = mnemonic == "TestRunner"
    {if(test? and rem(seed, 2) == 0, do: 2000, else: 1000), not (test? and rem(seed, 100) == 7)}
  end

  # A build's spawn is kept as `{action, version, mnemonic, start | nil (a hit), ms}`; the
  # log entry is made when the log is encoded.
  def log(build) do
    Synth.encode(
      build.id,
      Enum.map(build.spawns, fn
        {action, version, mnemonic, nil, _ms} -> action |> entry(version, mnemonic) |> Map.put(:hit, true)
        {action, version, mnemonic, start, ms} -> action |> entry(version, mnemonic) |> Map.merge(%{start: start, ms: ms})
      end)
    )
  end

  @doc """
  The builds, in start order: `%{id, project, start, host, spawns}` where a spawn is the
  map `Synth.encode/2` takes plus `:cores_milli`.
  """
  def builds(projects, n_builds, opts) do
    shared_pool = opts.shared_pool
    actions = Map.new(projects, &{&1.index, app_actions(&1.index, shared_pool, opts)})
    waves = max(div(n_builds, min(opts.wave, length(projects))), 1)
    span_ms = opts.hours * 3_600_000
    t0 = DateTime.add(opts.now, -(span_ms + 600_000), :millisecond)

    {builds, _state} =
      Enum.flat_map_reduce(1..waves, %{versions: %{}, hosts: [], caches: %{}, host_seq: 0}, fn wave, state ->
        wave_start = DateTime.add(t0, div(span_ms * (wave - 1), waves), :millisecond)
        apps = Enum.take_random(projects, min(opts.wave, length(projects)))

        # what this commit changed
        bumped =
          for(_ <- 1..max(div(shared_pool, 100), 1), do: {:shared, :rand.uniform(shared_pool)}) ++
            for p <- apps, {{:app, _}, _} = a <- actions[p.index], :rand.uniform() < 0.1, do: a

        versions = Enum.reduce(bumped, state.versions, &Map.update(&2, &1, 1, fn v -> v + 1 end))

        {builds, state} =
          apps
          |> Enum.map(&{&1, :rand.uniform(90_000)})
          |> Enum.sort_by(&elem(&1, 1))
          |> Enum.map_reduce(%{state | versions: versions}, fn {project, offset}, state ->
            {host, state} = pick_host(state, wave)
            cache = Map.get(state.caches, host, MapSet.new())
            start = DateTime.add(wave_start, offset, :millisecond)

            {spawns, {_lanes, cache}} =
              Enum.map_reduce(actions[project.index], {List.duplicate(0, @lanes), cache}, fn action, {lanes, cache} ->
                version = Map.get(versions, action, 0)
                mnemonic = mnemonic(action)

                if MapSet.member?(cache, {action, version}) do
                  {{action, version, mnemonic, nil, 0}, {lanes, cache}}
                else
                  ms = duration(action, mnemonic)
                  at = Enum.min(lanes)
                  lanes = List.replace_at(lanes, Enum.find_index(lanes, &(&1 == at)), at + ms)

                  {{action, version, mnemonic, DateTime.add(start, at, :millisecond), ms},
                   {lanes, MapSet.put(cache, {action, version})}}
                end
              end)

            build = %{id: Ecto.UUID.generate(), project: project, start: start, host: host, spawns: spawns}
            {build, %{state | caches: Map.put(state.caches, host, cache)}}
          end)

        {builds, state}
      end)

    builds
  end

  # A new machine 35 % of the time, else one of the 60 most recent not used in this wave.
  defp pick_host(state, wave) do
    free = Enum.reject(Enum.take(state.hosts, 60), fn {_host, used} -> used == wave end)

    if free == [] or :rand.uniform() < 0.35 do
      host = "go-ci-#{state.host_seq + 1}"
      {host, %{state | hosts: [{host, wave} | state.hosts], host_seq: state.host_seq + 1}}
    else
      {host, _} = Enum.random(free)
      hosts = Enum.map(state.hosts, fn {h, w} -> if h == host, do: {h, wave}, else: {h, w} end)
      {host, %{state | hosts: hosts}}
    end
  end

  # --- brute force -----------------------------------------------------------------------------

  @doc """
  Every keyed execution of the builds, classed the way docs/rbe-opportunity.md defines:
  `%{project_id => %{class => {n, wall ms, core ms}}}` plus hits and executed counts.
  """
  def expected(builds) do
    executions =
      for b <- builds,
          {{action, version, mnemonic, at, ms}, ordinal} <- Enum.with_index(b.spawns),
          at != nil,
          {cores_milli, true} <- [traits(action, mnemonic)] do
        start = DateTime.to_unix(at, :millisecond)

        %{
          key: {action, version},
          project: b.project.id,
          order: {start + ms, start, b.id, ordinal},
          start: start,
          ms: ms,
          core: div(ms * cores_milli, 1000)
        }
      end

    classes =
      executions
      |> Enum.group_by(& &1.key)
      |> Enum.flat_map(fn {_key, execs} ->
        first = Enum.min_by(execs, & &1.order)
        first_finish = elem(first.order, 0)
        own = execs |> Enum.group_by(& &1.project) |> Map.new(fn {p, es} -> {p, Enum.min_by(es, & &1.order)} end)

        for e <- execs do
          mine = own[e.project]
          mine? = mine.order == e.order

          class =
            cond do
              e.order == first.order -> "first"
              e.start < first_finish -> if(mine?, do: "racing_x", else: "racing")
              not mine? and e.start >= elem(mine.order, 0) -> "seq"
              true -> "seq_x"
            end

          {e.project, class, e}
        end
      end)

    by_project =
      Enum.reduce(classes, %{}, fn {project, class, e}, acc ->
        Map.update(acc, project, %{class => {1, e.ms, e.core}}, fn m ->
          Map.update(m, class, {1, e.ms, e.core}, fn {n, ms, core} -> {n + 1, ms + e.ms, core + e.core} end)
        end)
      end)

    hits =
      builds
      |> Enum.map(fn b -> {b.project.id, Enum.count(b.spawns, &(elem(&1, 3) == nil))} end)
      |> Enum.reduce(%{}, fn {p, n}, acc -> Map.update(acc, p, n, &(&1 + n)) end)

    %{classes: by_project, hits: hits, executions: length(executions)}
  end

  def sum_classes(expected, project_ids) do
    for p <- project_ids, {class, cell} <- Map.get(expected.classes, p, %{}), reduce: %{} do
      acc -> Map.update(acc, class, cell, fn {n, ms, core} -> {n + elem(cell, 0), ms + elem(cell, 1), core + elem(cell, 2)} end)
    end
  end

  @doc "Compares a report (JSON) with the expected classes; returns the mismatches."
  def compare(report, classes, hits) do
    cell = fn class -> Map.get(classes, class, {0, 0, 0}) end
    add = fn a, b -> {elem(a, 0) + elem(b, 0), elem(a, 1) + elem(b, 1), elem(a, 2) + elem(b, 2)} end
    got = fn path -> m = get_in(report, path); {m["n"], m["ms"], m["core_ms"]} end

    [
      {"sequential, within the project", got.(~w(cache same_project)), cell.("seq")},
      {"sequential, across projects", got.(~w(cache cross_project)), cell.("seq_x")},
      {"racing (all)", got.(~w(racing total)), add.(cell.("racing"), cell.("racing_x"))},
      {"racing, across projects", got.(~w(racing cross_project)), cell.("racing_x")},
      {"cache hits", {report["cache"]["hits"], 0, 0}, {hits, 0, 0}}
    ]
    |> Enum.map(fn {name, got, want} -> %{name: name, got: Tuple.to_list(got), expected: Tuple.to_list(want), ok: got == want} end)
  end

  # --- driving ---------------------------------------------------------------------------------

  def insert_builds(builds) do
    builds
    |> Enum.map(fn b ->
      wall = b.spawns |> Enum.map(&elem(&1, 4)) |> Enum.sum()
      duration = div(wall, @lanes) + 20_000
      finish = DateTime.add(b.start, duration, :millisecond)

      %{
        id: b.id,
        project_id: b.project.id,
        status: "succeeded",
        exit_code_name: "SUCCESS",
        exit_code: 0,
        command: "test",
        host: b.host,
        user_name: "ci",
        started_at: b.start,
        finished_at: finish,
        duration_ms: duration,
        wall_ms: duration,
        execution_ms: duration - 15_000,
        critical_path_ms: div(duration, 2),
        stream_finished: true,
        lifecycle_finished: true,
        tags: %{"ci" => "true", "branch" => "main"},
        inserted_at: finish,
        updated_at: finish
      }
    end)
    |> Enum.chunk_every(200)
    |> Enum.each(&Repo.insert_all(Invocation, &1))
  end

  def put(url, key, body) do
    request =
      {String.to_charlist(url), [{~c"x-api-key", String.to_charlist(key)}, {~c"connection", ~c"close"}],
       ~c"application/octet-stream", body}

    case :httpc.request(:put, request, [timeout: 120_000], []) do
      {:ok, {{_, 201, _}, _, _}} -> :ok
      other -> raise "upload failed: #{inspect(other)}"
    end
  end

  def get_json(url) do
    started = System.monotonic_time(:millisecond)
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 600_000], body_format: :binary)
    {System.monotonic_time(:millisecond) - started, Jason.decode!(body)}
  end

  def q(sql, params \\ []), do: Repo.query!(sql, params, timeout: 600_000).rows

  def pg_cpu_seconds do
    {out, 0} = System.cmd("ps", ["-Ao", "time,command"])

    out
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "postgres:"))
    |> Enum.map(fn line ->
      [time | _] = String.split(String.trim(line), " ", parts: 2)

      time
      |> String.split(":")
      |> Enum.map(&elem(Float.parse(&1), 0))
      |> Enum.reduce(0.0, fn part, acc -> acc * 60 + part end)
    end)
    |> Enum.sum()
  end

  def sizes do
    for [table] <- [["spawns"], ["spawn_inputs"], ["action_keys"], ["exec_properties"], ["invocation_rollups"], ["oban_jobs"]], into: %{} do
      [[rows, bytes]] = q("SELECT count(*), pg_total_relation_size($1::text::regclass) FROM #{table}", [table])
      {table, %{rows: rows, bytes: bytes}}
    end
  end

  def percentile([], _), do: nil
  def percentile(values, p), do: values |> Enum.sort() |> Enum.at(min(round(length(values) * p), length(values) - 1))
end

alias Conveyor.Repo
import Ecto.Query

opts = %{
  now: DateTime.utc_now(),
  spawns_min: RbeScale.env("SPAWNS_MIN", 500),
  spawns_max: RbeScale.env("SPAWNS_MAX", 4000),
  share_min: 0.6,
  share_max: 0.8,
  shared_pool: RbeScale.env("SHARED_POOL", 12_000),
  wave: RbeScale.env("WAVE", 50),
  hours: RbeScale.env("HOURS", 6)
}

n_projects = RbeScale.env("PROJECTS", 360)
n_builds = RbeScale.env("BUILDS", 2000)
nodes = System.get_env("NODES", "http://localhost:4199") |> String.split(",")
uploaders = RbeScale.env("UPLOADERS", 8)
label = System.get_env("LABEL", "run")
:rand.seed(:exsss, {RbeScale.env("SEED", 27), 9, 360})

IO.puts("projects #{n_projects}, builds #{n_builds}, nodes #{length(nodes)}")
projects = RbeScale.projects(n_projects)
{gen_us, builds} = :timer.tc(fn -> RbeScale.builds(projects, n_builds, opts) end)
spawn_count = builds |> Enum.map(&length(&1.spawns)) |> Enum.sum()
IO.puts("generated #{length(builds)} builds, #{spawn_count} spawns in #{div(gen_us, 1000)} ms")
expected = RbeScale.expected(builds)
IO.puts("expected: #{expected.executions} keyed executions")
RbeScale.insert_builds(builds)

# --- the measured phase ------------------------------------------------------------------------
RbeScale.q("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
RbeScale.q("SELECT pg_stat_statements_reset()")
RbeScale.q("CHECKPOINT")
[[wal0]] = RbeScale.q("SELECT pg_current_wal_lsn()::text")
[[deadlocks0, commits0, rollbacks0]] = RbeScale.q("SELECT deadlocks, xact_commit, xact_rollback FROM pg_stat_database WHERE datname = current_database()")
cpu0 = RbeScale.pg_cpu_seconds()
sizes0 = RbeScale.sizes()
t_start = System.monotonic_time(:millisecond)
wall_start = DateTime.utc_now()

sampler =
  Task.async(fn ->
    Stream.repeatedly(fn ->
      Process.sleep(500)

      [[waiting, longest]] =
        RbeScale.q("""
        SELECT count(*), coalesce(max(extract(epoch FROM now() - state_change)), 0)::float
        FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'
        """)

      {waiting, longest}
    end)
    |> Enum.reduce_while([], fn sample, acc ->
      receive do
        :stop -> {:halt, acc}
      after
        0 -> {:cont, [sample | acc]}
      end
    end)
  end)

# Roughly in start order, as CI would: shuffled inside windows of 100 builds. A log is
# encoded by the uploader right before it is sent (keeping 2,000 logs on disk first costs
# gigabytes); the parse queue, not the uploaders, is what limits the run.
log_bytes =
  builds
  |> Enum.chunk_every(100)
  |> Enum.flat_map(&Enum.shuffle/1)
  |> Enum.with_index()
  |> Task.async_stream(
    fn {b, i} ->
      node = Enum.at(nodes, rem(i, length(nodes)))
      body = RbeScale.log(b)
      RbeScale.put("#{node}/api/v1/invocations/#{b.id}/artifacts/execution.log.zst", b.project.key, body)
      byte_size(body)
    end,
    max_concurrency: uploaders,
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, n} -> n end)

t_uploaded = System.monotonic_time(:millisecond)
IO.puts("uploaded in #{div(t_uploaded - t_start, 1000)} s; waiting for the parse queue")
ids = Enum.map(builds, & &1.id)

Stream.repeatedly(fn ->
  Process.sleep(1000)
  ids |> Enum.chunk_every(1000) |> Enum.map(fn chunk -> Repo.aggregate(from(i in Conveyor.Invocations.Invocation, where: i.id in ^chunk and i.exec_log_status == "parsed"), :count) end) |> Enum.sum()
end)
|> Enum.reduce_while(0, fn parsed, last ->
  if parsed != last and rem(parsed, 100) < 4, do: IO.puts("  parsed #{parsed}/#{length(ids)} at #{div(System.monotonic_time(:millisecond) - t_start, 1000)} s")
  if parsed == length(ids), do: {:halt, parsed}, else: {:cont, parsed}
end)

t_done = System.monotonic_time(:millisecond)
send(sampler.pid, :stop)
samples = Task.await(sampler, 10_000)
cpu1 = RbeScale.pg_cpu_seconds()
[[wal_bytes]] = RbeScale.q("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), $1::text::pg_lsn)::bigint", [wal0])
[[deadlocks1, commits1, rollbacks1]] = RbeScale.q("SELECT deadlocks, xact_commit, xact_rollback FROM pg_stat_database WHERE datname = current_database()")
[[exec_ms]] = RbeScale.q("SELECT sum(total_exec_time)::float FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())")

top =
  RbeScale.q("""
  SELECT left(regexp_replace(query, '\\s+', ' ', 'g'), 110), calls, round(total_exec_time)::bigint, round(mean_exec_time::numeric, 2)::float
  FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY total_exec_time DESC LIMIT 12
  """)

jobs =
  RbeScale.q("""
  SELECT state, attempt, extract(epoch FROM completed_at - attempted_at)::float * 1000, jsonb_array_length(to_jsonb(errors))
  FROM oban_jobs WHERE queue = 'parse' AND inserted_at >= $1
  """, [wall_start])

parse_ms = for [state, _, ms, _] <- jobs, state == "completed", ms != nil, do: ms
sizes1 = RbeScale.sizes()
seconds = (t_done - t_start) / 1000

per_build = fn table -> div(sizes1[table].bytes - sizes0[table].bytes, length(builds)) end

load = %{
  seconds: seconds,
  upload_seconds: (t_uploaded - t_start) / 1000,
  logs_per_min: Float.round(length(builds) / seconds * 60, 1),
  spawns_per_s: round(spawn_count / seconds),
  parse_ms_p50: RbeScale.percentile(parse_ms, 0.5) |> round(),
  parse_ms_p99: RbeScale.percentile(parse_ms, 0.99) |> round(),
  parse_ms_max: Enum.max(parse_ms) |> round(),
  jobs: Enum.frequencies_by(jobs, &hd/1),
  retried_jobs: Enum.count(jobs, fn [_, attempt, _, _] -> attempt > 1 end),
  job_errors: jobs |> Enum.map(&Enum.at(&1, 3)) |> Enum.sum(),
  pg_cpu_seconds: Float.round(cpu1 - cpu0, 1),
  pg_exec_seconds: Float.round(exec_ms / 1000, 1),
  deadlocks: deadlocks1 - deadlocks0,
  commits: commits1 - commits0,
  rollbacks: rollbacks1 - rollbacks0,
  lock_wait_samples: Enum.count(samples, fn {n, _} -> n > 0 end),
  samples: length(samples),
  max_backends_waiting: samples |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end),
  longest_lock_wait_s: samples |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end) |> Float.round(2),
  wal_bytes_per_build: div(wal_bytes, length(builds)),
  bytes_per_build: Map.new(~w(spawns spawn_inputs action_keys exec_properties), &{&1, per_build.(&1)}),
  rows: Map.new(sizes1, fn {t, s} -> {t, s.rows} end),
  spawns_per_build: div(spawn_count, length(builds)),
  log_bytes_per_build: div(Enum.sum(log_bytes), length(builds))
}

IO.inspect(load, label: "load", limit: :infinity)
IO.puts("top statements (text, calls, total ms, mean ms):")
Enum.each(top, &IO.inspect(&1, limit: :infinity))

# --- reading -----------------------------------------------------------------------------------
node = hd(nodes)
member_ids = Enum.map(projects, & &1.id)
hours = RbeScale.q("SELECT DISTINCT project_id, date_trunc('hour', started_at) FROM invocations WHERE project_id = ANY($1)", [member_ids])

roll_ms =
  hours
  |> Enum.take_random(40)
  |> Enum.map(fn [project_id, hour] ->
    {us, _} = :timer.tc(fn -> Conveyor.Metrics.Rollup.roll!(project_id, DateTime.from_naive!(hour, "Etc/UTC")) end)
    us / 1000
  end)

clear = fn ids -> RbeScale.q("DELETE FROM invocation_rollups WHERE project_id = ANY($1)", [ids]) end
sample = Enum.take_random(projects, 5)
clear.(member_ids)
RbeScale.q("SELECT pg_stat_statements_reset()")
{group_cold, group} = RbeScale.get_json("#{node}/groups/rbe-scale/rbe/json?range=24h")

cold_top =
  RbeScale.q("""
  SELECT left(regexp_replace(query, '\\s+', ' ', 'g'), 110), calls, round(total_exec_time)::bigint, round(mean_exec_time::numeric, 2)::float
  FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY total_exec_time DESC LIMIT 6
  """)

group_warm = for _ <- 1..5, do: elem(RbeScale.get_json("#{node}/groups/rbe-scale/rbe/json?range=24h"), 0)

project_times =
  for p <- sample do
    clear.([p.id])
    {cold, report} = RbeScale.get_json("#{node}/p/#{p.slug}/rbe/json?range=24h")
    warm = for _ <- 1..3, do: elem(RbeScale.get_json("#{node}/p/#{p.slug}/rbe/json?range=24h"), 0)
    {p, cold, Enum.min(warm), report}
  end

read = %{
  project_hours: length(hours),
  roll_hour_ms_p50: RbeScale.percentile(roll_ms, 0.5) |> round(),
  roll_hour_ms_max: Enum.max(roll_ms) |> round(),
  group_page_cold_ms: group_cold,
  group_page_warm_ms: Enum.min(group_warm),
  project_page_cold_ms: project_times |> Enum.map(&elem(&1, 1)) |> RbeScale.percentile(0.5),
  project_page_warm_ms: project_times |> Enum.map(&elem(&1, 2)) |> RbeScale.percentile(0.5),
  group_json_bytes: byte_size(Jason.encode!(group))
}

IO.inspect(read, label: "read")
IO.puts("statements of the cold group page:")
Enum.each(cold_top, &IO.inspect(&1, limit: :infinity))

# --- exactness ---------------------------------------------------------------------------------
checks =
  [{"group", RbeScale.compare(group["report"], RbeScale.sum_classes(expected, member_ids), expected.hits |> Map.values() |> Enum.sum())}] ++
    for {p, _, _, report} <- project_times do
      {p.slug, RbeScale.compare(report["report"], RbeScale.sum_classes(expected, [p.id]), Map.get(expected.hits, p.id, 0))}
    end

for {scope, rows} <- checks, row <- rows do
  IO.puts("#{if row.ok, do: "EXACT   ", else: "MISMATCH"} #{scope}: #{row.name} got #{inspect(row.got)} expected #{inspect(row.expected)}")
end

exact? = Enum.all?(checks, fn {_, rows} -> Enum.all?(rows, & &1.ok) end)
IO.puts(if exact?, do: "RESULT: exact", else: "RESULT: MISMATCH")

File.mkdir_p!("bench/results")
out = "bench/results/rbe_scale-#{label}.json"

File.write!(
  out,
  Jason.encode!(
    %{
      label: label,
      at: DateTime.utc_now(),
      projects: n_projects,
      builds: length(builds),
      spawns: spawn_count,
      nodes: length(nodes),
      model: Map.delete(opts, :now),
      load: load,
      read: read,
      exact: exact?,
      checks: Map.new(checks),
      top_statements: top,
      cold_page_statements: cold_top
    },
    pretty: true
  )
)

IO.puts("wrote #{out}")
