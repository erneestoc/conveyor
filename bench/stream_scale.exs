# Duplicate work from the event stream, a cache group of many projects (PLAN §28.5).
#
# Run through bench/stream_scale.sh. The model: PROJECTS projects in one cache group;
# BUILDS builds in waves of ten (a commit fans out to ten apps that start within 90 s of
# each other, four minutes between waves); each build is one of the recorded builds
# (buildtools three times as often as abseil), moved to its start; 15 % name no commit.
# The same few recordings repeat, so most executions repeat a key: across projects,
# across commits, racing inside a wave.
#
# The builds are replayed at once (CONCURRENCY streams) through gRPC. The node merges the
# keys of each build when it ends (`Conveyor.Workers.StreamKeys`); the driver then reads
# the group's report the way the page does.
#
# Exactness: the driver computes every record from the same events
# (`Conveyor.Rbe.StreamActions.record/8`) and classes every execution by brute force in
# both key spaces (first by finish per key in the group; racing or sequential against
# it; in its own project or only across projects) and compares counts and wall time per
# class with the report. Counts must be equal; times within the rounding of the hourly
# cells (1 ms per cell).
Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Conveyor.Repo.start_link(pool_size: 10)

defmodule StreamScale do
  alias Conveyor.{Projects, Repo}
  alias Conveyor.Rbe.{Groups, Stream, StreamActions}
  alias Conveyor.Seed.StreamDemo

  @group "stream-scale"
  @fixtures ~w(buildtools_a1 buildtools_b1 buildtools_a2 buildtools_a1 buildtools_b1 buildtools_a2 buildtools_a1 buildtools_b1 buildtools_a2 abseil_a1 abseil_b1 abseil_b2)

  def env(name, default), do: String.to_integer(System.get_env(name, to_string(default)))
  def q(sql, params \\ []), do: Repo.query!(sql, params, timeout: 600_000).rows

  def projects(n) do
    for i <- 1..n do
      slug = "app-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
      {:ok, project} = Projects.create_project(%{slug: slug, name: "App #{i}"})
      {:ok, project} = Groups.put(project, @group)
      {:ok, _, key} = Projects.create_api_key(project, %{name: "scale", scopes: ["ingest"]})
      {project, key}
    end
  end

  def plan(projects, n, base) do
    for i <- 0..(n - 1) do
      wave = div(i, 10)
      {project, key} = Enum.random(projects)
      name = Enum.random(@fixtures)
      # Distinct to the microsecond: no two executions tie.
      offset_us = wave * 240_000_000 + :rand.uniform(90_000_000) + i

      %{
        id: Conveyor.Bep.Replay.uuid(),
        project: project.id,
        key: key,
        name: name,
        commit: if(:rand.uniform(100) > 15, do: "c#{wave}"),
        shift:
          DateTime.diff(DateTime.add(base, offset_us, :microsecond), StreamDemo.started_at(name), :microsecond)
      }
    end
  end

  def events(b) do
    tags = if b.commit, do: %{"COMMIT_SHA" => b.commit}, else: %{}
    StreamDemo.events(b.name, shift_us: b.shift, tags: tags)
  end

  defp us(nil), do: nil
  defp us(t), do: t.seconds * 1_000_000 + div(t.nanos, 1000)

  # The executions of a build, from its events and nothing else.
  def executions(b) do
    events = events(b)

    start =
      Enum.find_value(events, fn
        %{payload: {:started, s}} -> us(s.start_time)
        _ -> nil
      end)

    for {%{id: %{id: {:action_completed, aid}}, payload: {:action, %{success: true} = a}}, seq} <-
          Enum.with_index(events, 1),
        r =
          StreamActions.record(
            if(a.label in [nil, ""], do: aid.label, else: a.label),
            a.type,
            aid.primary_output,
            a.command_line,
            us(a.start_time),
            us(a.end_time),
            start,
            seq
          ),
        StreamActions.execution?(r) do
      {key, at, duration, _, _, _, seq} = r
      %{build: b.id, project: b.project, commit: b.commit, key: key, start: at, finish: at + duration, us: duration, seq: seq}
    end
  end

  defp rank(e), do: {e.finish, e.start, e.build, e.seq}

  # class → {count, µs} of the executions, keyed by `key_of` (nil: not in this space).
  def classes(executions, key_of) do
    {keyed, unkeyed} = Enum.split_with(executions, &key_of.(&1))
    firsts = fn list, by -> list |> Enum.group_by(by) |> Map.new(fn {k, es} -> {k, Enum.min_by(es, &rank/1)} end) end
    group = firsts.(keyed, key_of)
    own = firsts.(keyed, &{&1.project, key_of.(&1)})

    against = fn e, first ->
      cond do
        first == e -> :first
        e.start < first.finish -> :racing
        true -> :sequential
      end
    end

    Enum.reduce(keyed, %{"nocommit" => count(unkeyed)}, fn e, acc ->
      class =
        case {against.(e, group[key_of.(e)]), against.(e, own[{e.project, key_of.(e)}])} do
          {:first, _} -> "first"
          {:sequential, :sequential} -> "sequential"
          {:sequential, _} -> "sequential_cross"
          {:racing, :racing} -> "racing"
          {:racing, _} -> "racing_cross"
        end

      Map.update(acc, class, {1, e.us}, fn {n, us} -> {n + 1, us + e.us} end)
    end)
  end

  defp count(list), do: {length(list), list |> Enum.map(& &1.us) |> Enum.sum()}

  # What the report says, in the same shape.
  def reported(figure) do
    cell = fn c -> {c.n, c.ms * 1000} end
    {xn, xus} = cell.(figure.cross_project)
    {rn, rus} = cell.(figure.racing)
    {sn, sus} = cell.(figure.sequential)

    %{
      "first" => cell.(figure.first),
      "nocommit" => cell.(figure.no_commit),
      "racing+sequential" => {rn + sn, rus + sus},
      "cross" => {xn, xus}
    }
  end

  def expected(classes) do
    get = &Map.get(classes, &1, {0, 0})
    add = fn names -> names |> Enum.map(get) |> Enum.reduce({0, 0}, fn {n, us}, {an, aus} -> {an + n, aus + us} end) end

    %{
      "first" => get.("first"),
      "nocommit" => get.("nocommit"),
      "racing+sequential" => add.(~w(racing racing_cross sequential sequential_cross)),
      "cross" => add.(~w(racing_cross sequential_cross))
    }
  end

  def percentile([], _), do: nil
  def percentile(values, p), do: values |> Enum.sort() |> Enum.at(min(round(length(values) * p), length(values) - 1))

  def commit_key(e), do: e.commit && Stream.commit_key(e.key, e.commit)
end

:rand.seed(:exsss, {StreamScale.env("SEED", 7), 2, 3})
label = System.get_env("LABEL", "run")
[host, port] = System.get_env("GRPC", "localhost:1999") |> String.split(":")
concurrency = StreamScale.env("CONCURRENCY", 40)
projects = StreamScale.projects(StreamScale.env("PROJECTS", 60))
now = DateTime.utc_now()
base = %{DateTime.add(now, -4 * 3600, :second) | minute: 0, second: 0, microsecond: {0, 6}}
builds = StreamScale.plan(projects, StreamScale.env("BUILDS", 300), base)
IO.puts("#{length(projects)} projects, #{length(builds)} builds, #{concurrency} streams at once")

[[deadlocks0]] = StreamScale.q("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")
[[wal0]] = StreamScale.q("SELECT wal_bytes::bigint FROM pg_stat_wal")
parent = self()

sampler =
  spawn_link(fn ->
    Stream.repeatedly(fn ->
      receive do
        :stop -> :stop
      after
        200 ->
          [[n, longest]] =
            StreamScale.q("""
            SELECT count(*), coalesce(max(extract(epoch FROM now() - query_start)), 0)::float8
            FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()
            """)

          {n, longest}
      end
    end)
    |> Enum.take_while(&(&1 != :stop))
    |> then(&send(parent, {:samples, &1}))
  end)

started = System.monotonic_time(:millisecond)

results =
  builds
  |> Task.async_stream(
    fn b ->
      Conveyor.Bep.Replay.run(StreamScale.events(b),
        host: host,
        port: String.to_integer(port),
        api_key: b.key,
        invocation_id: b.id,
        retries: 3
      )
    end,
    max_concurrency: concurrency,
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, r} -> r end)

ingest_ms = System.monotonic_time(:millisecond) - started
failed = Enum.count(results, &(not match?({:ok, _}, &1)))
events = results |> Enum.map(fn {:ok, r} -> r.sent; _ -> 0 end) |> Enum.sum()

# The node merges keys as builds end; wait until none is pending.
Stream.repeatedly(fn ->
  [[n]] = StreamScale.q("SELECT count(*) FROM invocations WHERE stream_actions > 0 AND stream_keys_at IS NULL")
  if n > 0, do: Process.sleep(250)
  n
end)
|> Enum.find(&(&1 == 0 or System.monotonic_time(:millisecond) - started > 900_000))

merged_ms = System.monotonic_time(:millisecond) - started
send(sampler, :stop)
samples = receive do {:samples, s} -> s end
[[deadlocks1]] = StreamScale.q("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")
[[wal1]] = StreamScale.q("SELECT wal_bytes::bigint FROM pg_stat_wal")

merge_ms =
  StreamScale.q("""
  SELECT (extract(epoch FROM completed_at - attempted_at) * 1000)::float8
  FROM oban_jobs WHERE worker = 'Conveyor.Workers.StreamKeys' AND state = 'completed'
  """)
  |> List.flatten()

[[actions, with_events]] =
  StreamScale.q("SELECT coalesce(sum(stream_actions), 0)::bigint, count(*) FROM invocations WHERE stream_actions > 0")

sizes =
  Map.new(~w(stream_actions action_keys invocations), fn t ->
    [[bytes, rows]] = StreamScale.q("SELECT pg_total_relation_size('#{t}')::bigint, (SELECT count(*) FROM #{t})")
    {t, %{bytes: bytes, rows: rows}}
  end)

[[commit_rows]] = StreamScale.q("SELECT count(*) FROM action_keys WHERE out = 1 AND octet_length(key) = 8")
[[group_rows]] = StreamScale.q("SELECT count(*) FROM action_keys WHERE scope < 0")

# The group's report, the way the page loads it: the first read rolls every stale hour.
group = Conveyor.Rbe.Groups.get_by_name("stream-scale")
admin = %Conveyor.Accounts.Scope{admin?: true}
{cold_us, report} = :timer.tc(fn -> ConveyorWeb.RbeReport.group(admin, group, "24h") end)
{warm_us, _} = :timer.tc(fn -> ConveyorWeb.RbeReport.group(admin, group, "24h") end)

executions = Enum.flat_map(builds, &StreamScale.executions/1)
any = StreamScale.expected(StreamScale.classes(executions, & &1.key))
same = StreamScale.expected(StreamScale.classes(executions, &StreamScale.commit_key/1))
stream = report.stream

mismatches =
  for {space, expected, figure} <- [{"any", any, stream.any_commit}, {"same", same, stream.same_commit}],
      got = StreamScale.reported(figure),
      {class, {n, us}} <- expected,
      {gn, gus} = got[class],
      space != "any" or class != "nocommit",
      gn != n or abs(gus - us) > 2_000_000,
      do: "#{space} #{class}: expected #{n} (#{div(us, 1000)} ms), reported #{gn} (#{div(gus, 1000)} ms)"

out = %{
  label: label,
  projects: length(projects),
  builds: length(builds),
  failed_streams: failed,
  events: events,
  actions: actions,
  builds_with_events: with_events,
  executions: length(executions),
  ingest_s: ingest_ms / 1000,
  all_merged_s: merged_ms / 1000,
  actions_per_s: Float.round(actions * 1000 / ingest_ms, 1),
  merge_ms: %{n: length(merge_ms), p50: StreamScale.percentile(merge_ms, 0.5), p99: StreamScale.percentile(merge_ms, 0.99), max: Enum.max(merge_ms, fn -> nil end)},
  deadlocks: deadlocks1 - deadlocks0,
  lock_wait_samples: Enum.count(samples, fn {n, _} -> n > 0 end),
  samples: length(samples),
  longest_lock_wait_s: samples |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end) |> Float.round(2),
  wal_bytes: wal1 - wal0,
  sizes: sizes,
  action_keys_same_commit_rows: commit_rows,
  action_keys_group_scope_rows: group_rows,
  report_cold_ms: div(cold_us, 1000),
  report_warm_ms: div(warm_us, 1000),
  pending: stream.pending_builds,
  reported_builds: stream.builds,
  any_commit: StreamScale.reported(stream.any_commit) |> Map.new(fn {k, {n, us}} -> {k, [n, div(us, 1000)]} end),
  same_commit: StreamScale.reported(stream.same_commit) |> Map.new(fn {k, {n, us}} -> {k, [n, div(us, 1000)]} end),
  estimate: stream.estimate && %{n: stream.estimate.duplicate.n, ms: stream.estimate.duplicate.ms},
  mismatches: mismatches
}

File.mkdir_p!("bench/results")
File.write!("bench/results/stream_scale-#{label}.json", Jason.encode!(out, pretty: true))
IO.puts(Jason.encode!(Map.drop(out, [:mismatches]), pretty: true))
IO.puts(if mismatches == [], do: "RESULT: exact", else: "RESULT: MISMATCH\n" <> Enum.join(mismatches, "\n"))
