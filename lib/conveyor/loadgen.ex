defmodule Conveyor.Loadgen do
  @moduledoc """
  Load generator for the scale campaign (M7): replays recorded BEP fixtures as concurrent
  Bazel-like clients against one or more Conveyor gRPC endpoints and reports throughput,
  failures and client-observed ack latency percentiles.

      Conveyor.Loadgen.run(
        fixtures: ["test/fixtures/bep/*.bep"],
        hosts: ["localhost:1985", "localhost:1986"],
        api_key: "conveyor_...",
        streams: 200,
        builds: 1_000,
        delay_ms: 0,
        jitter_ms: 0,
        drop_after: nil,
        duplicate_every: nil
      )

  That is a closed loop: `streams` clients, each starting a build when its last one ended,
  so a slow server is sent less. `arrival_rate: n` (builds per second) makes it an open
  loop: builds start on schedule whatever the completions, `streams` is ignored, and the
  report carries `peak_streams` and `max_start_lag_ms`. Use it for overload experiments; a
  closed loop hides them (coordinated omission).

  Also available as `mix conveyor.loadgen` and the `bes_loadgen` escript.
  """

  alias Conveyor.Bep.{Fixture, Replay}

  @type report :: map()

  @spec run(keyword()) :: report()
  def run(opts) do
    fixtures =
      opts
      |> Keyword.get(:fixtures, ["test/fixtures/bep/*.bep"])
      |> Enum.flat_map(&Path.wildcard/1)

    if fixtures == [], do: raise(ArgumentError, "no fixtures matched")

    hosts = opts |> Keyword.get(:hosts, ["localhost:1985"]) |> Enum.map(&parse_host/1)
    streams = Keyword.get(opts, :streams, 10)
    builds = Keyword.get(opts, :builds, streams * 5)
    duration_ms = Keyword.get(opts, :duration_ms)
    jitter = Keyword.get(opts, :jitter_ms, 0)
    retries = Keyword.get(opts, :retries, 0)
    on_build = Keyword.get(opts, :on_build, fn _ -> :ok end)
    events_by_file = Map.new(fixtures, &{&1, &1 |> Fixture.read!() |> Replay.pre_encode()})
    deadline = duration_ms && System.monotonic_time(:millisecond) + duration_ms
    started = System.monotonic_time(:millisecond)
    # Wall clock of the start, to line the report's timeline up with a server's.
    started_at = System.system_time(:millisecond)

    replay = fn {i, file} ->
      if jitter > 0, do: Process.sleep(:rand.uniform(jitter))

      # Like Bazel after a failed upload, the client retries the same invocation (same
      # ids, resumed from the last ack) against the next host, so a build whose node
      # died mid-stream finishes on another node.
      replay_opts =
        Keyword.take(opts, [
          :api_key,
          :delay_ms,
          :drop_after,
          :duplicate_every,
          :tls,
          :ack_timeout_ms,
          :retry_delay_ms
        ]) ++
          [
            hosts: hosts,
            host_offset: i,
            retries: retries,
            invocation_id: Replay.uuid(),
            build_id: Replay.uuid()
          ]

      result = Replay.run(events_by_file[file], replay_opts)
      on_build.(result)
      {file, result, System.monotonic_time(:millisecond) - started}
    end

    plan = build_plan(fixtures, builds, deadline)

    {results, extra} =
      case Keyword.get(opts, :arrival_rate) do
        nil -> {closed_loop(plan, replay, streams), %{}}
        rate -> open_loop(plan, replay, rate, started)
      end

    elapsed_ms = max(System.monotonic_time(:millisecond) - started, 1)

    results
    |> summarize(elapsed_ms, streams)
    |> Map.merge(extra)
    |> Map.put(:started_at_unix_ms, started_at)
  end

  # A fixed number of clients, each starting its next build when the last one ended. The
  # load follows the server: when it slows down, so do the arrivals.
  defp closed_loop(plan, replay, streams) do
    plan
    |> Task.async_stream(replay, max_concurrency: streams, timeout: :infinity, ordered: false)
    |> Enum.map(fn {:ok, r} -> r end)
  end

  # Builds start at a fixed rate whatever the completions, as CI jobs do: a server that
  # falls behind faces more open streams, not fewer arrivals. Build `i` is due at
  # `i / rate` seconds; a generator that cannot keep up starts late and says so
  # (`max_start_lag_ms`) instead of silently lowering the rate.
  defp open_loop(plan, replay, rate, started) do
    counter = :counters.new(2, [:write_concurrency])
    peak = :atomics.new(1, signed: false)

    {tasks, lag} =
      Enum.map_reduce(plan, 0, fn {i, _file} = build, lag ->
        due = started + round(i * 1000 / rate)
        wait = due - System.monotonic_time(:millisecond)
        if wait > 0, do: Process.sleep(wait)

        task =
          Task.async(fn ->
            :counters.add(counter, 1, 1)
            open = :counters.get(counter, 1)
            if open > :atomics.get(peak, 1), do: :atomics.put(peak, 1, open)

            try do
              replay.(build)
            after
              :counters.sub(counter, 1, 1)
            end
          end)

        {task, max(lag, -wait)}
      end)

    results = Task.await_many(tasks, :infinity)
    {results, %{arrival_rate: rate, peak_streams: :atomics.get(peak, 1), max_start_lag_ms: lag}}
  end

  # Cycles through the fixtures; with a deadline the plan is lazy and stops when time is up.
  defp build_plan(fixtures, builds, nil) do
    Stream.cycle(fixtures)
    |> Stream.take(builds)
    |> Stream.with_index()
    |> Enum.map(fn {f, i} -> {i, f} end)
  end

  defp build_plan(fixtures, _builds, deadline) do
    Stream.cycle(fixtures)
    |> Stream.with_index()
    |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
    |> Stream.map(fn {f, i} -> {i, f} end)
  end

  defp parse_host(host_port) do
    case String.split(host_port, ":") do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 1985}
    end
  end

  @doc false
  def summarize(results, elapsed_ms, streams) do
    results =
      Enum.map(results, fn
        {file, result} -> {file, result, elapsed_ms}
        {_file, _result, _at} = r -> r
      end)

    ok = for {_, {:ok, r}, _} <- results, do: r

    failed =
      for {file, {:error, reason}, _} <- results,
          do: %{file: Path.basename(file), reason: inspect(reason), kind: failure_kind(reason)}

    events = Enum.reduce(ok, 0, &(&1.sent + &2))
    missing = Enum.reduce(ok, 0, fn r, acc -> acc + (r.sent - length(Enum.uniq(r.acks))) end)
    latencies = ok |> Enum.flat_map(& &1.latencies_ms) |> Enum.sort()
    durations = ok |> Enum.map(& &1.duration_ms) |> Enum.sort()

    %{
      streams: streams,
      builds_total: length(results),
      builds_ok: length(ok),
      builds_failed: length(failed),
      failures: failed |> Enum.take(20) |> Enum.map(&Map.delete(&1, :kind)),
      failure_kinds: Enum.frequencies_by(failed, & &1.kind),
      events: events,
      retried_builds: Enum.count(ok, &(Map.get(&1, :attempts, 1) > 1)),
      # Reconnects of the builds that completed (each one a resend from the last ack).
      resends: Enum.reduce(ok, 0, &(Map.get(&1, :attempts, 1) - 1 + &2)),
      missing_acks: missing,
      elapsed_ms: elapsed_ms,
      events_per_second: Float.round(events * 1000 / elapsed_ms, 1),
      builds_per_minute: Float.round(length(ok) * 60_000 / elapsed_ms, 1),
      ack_latency_ms: percentiles(latencies),
      build_duration_ms: percentiles(durations),
      timeline: timeline(results),
      invocations: Enum.map(ok, &%{id: &1.invocation_id, sent: &1.sent})
    }
  end

  # What a failed build ended with, short enough to count: the gRPC status and the first
  # words of its message, or the shape of the error.
  defp failure_kind(%GRPC.RPCError{status: status, message: message}),
    do:
      "grpc #{status}: #{message |> to_string() |> String.split(~r/[(:;]/) |> hd() |> String.trim()}"

  defp failure_kind({kind, %GRPC.RPCError{} = error}) when is_atom(kind),
    do: "#{kind} #{failure_kind(error)}"

  defp failure_kind({kind, _}) when is_atom(kind), do: to_string(kind)
  defp failure_kind(kind) when is_atom(kind), do: to_string(kind)
  defp failure_kind(_other), do: "other"

  # Builds by the 10 s window they ended in, with the worst ack of the ones that completed:
  # how an overload builds up and how long the recovery takes.
  defp timeline(results) do
    results
    |> Enum.group_by(fn {_, _, at} -> div(at, 10_000) * 10 end)
    |> Enum.sort()
    |> Enum.map(fn {t_s, rs} ->
      acks = for {_, {:ok, r}, _} <- rs, l <- r.latencies_ms, do: l

      %{
        t_s: t_s,
        ok: Enum.count(rs, &match?({_, {:ok, _}, _}, &1)),
        failed: Enum.count(rs, &match?({_, {:error, _}, _}, &1)),
        ack_max_ms: if(acks == [], do: nil, else: acks |> Enum.max() |> round_ms())
      }
    end)
  end

  @doc "p50/p90/p99/max of a sorted list."
  def percentiles([]), do: %{p50: nil, p90: nil, p99: nil, max: nil, count: 0}

  def percentiles(sorted) do
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(trunc(q * n), n - 1)) |> round_ms() end

    %{
      p50: at.(0.50),
      p90: at.(0.90),
      p99: at.(0.99),
      max: List.last(sorted) |> round_ms(),
      count: n
    }
  end

  defp round_ms(v) when is_float(v), do: Float.round(v, 2)
  defp round_ms(v), do: v

  @doc "Human-readable one-screen report."
  def format(report) do
    lat = report.ack_latency_ms
    dur = report.build_duration_ms

    """
    builds     #{report.builds_ok}/#{report.builds_total} ok (#{report.builds_failed} failed), #{report.builds_per_minute} builds/min #{shape(report)}
    events     #{report.events} sent, #{report.missing_acks} missing acks, #{report.events_per_second} events/s, #{report.elapsed_ms} ms wall, #{report.retried_builds} builds retried
    ack ms     p50 #{lat.p50}  p90 #{lat.p90}  p99 #{lat.p99}  max #{lat.max}  (client-observed, n=#{lat.count})
    build ms   p50 #{dur.p50}  p90 #{dur.p90}  p99 #{dur.p99}  max #{dur.max}
    #{Enum.map_join(report.failure_kinds, "\\n", fn {kind, n} -> "  #{n} × #{kind}" end)}
    #{Enum.map_join(report.failures, "\\n", &"  FAILED #{&1.file}: #{&1.reason}")}
    """
  end

  defp shape(%{arrival_rate: rate} = report),
    do:
      "open loop at #{rate} builds/s (peak #{report.peak_streams} streams, latest start #{report.max_start_lag_ms} ms behind)"

  defp shape(report), do: "over #{report.streams} streams"
end
