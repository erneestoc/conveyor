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
    on_build = Keyword.get(opts, :on_build, fn _ -> :ok end)
    events_by_file = Map.new(fixtures, &{&1, Fixture.read!(&1)})
    deadline = duration_ms && System.monotonic_time(:millisecond) + duration_ms
    started = System.monotonic_time(:millisecond)

    results =
      build_plan(fixtures, builds, deadline)
      |> Task.async_stream(
        fn {i, file} ->
          if jitter > 0, do: Process.sleep(:rand.uniform(jitter))
          {host, port} = Enum.at(hosts, rem(i, length(hosts)))

          replay_opts =
            [host: host, port: port]
            |> Keyword.merge(
              Keyword.take(opts, [:api_key, :delay_ms, :drop_after, :duplicate_every])
            )

          result = Replay.run(events_by_file[file], replay_opts)
          on_build.(result)
          {file, result}
        end,
        max_concurrency: streams,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    elapsed_ms = max(System.monotonic_time(:millisecond) - started, 1)
    summarize(results, elapsed_ms, streams)
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
    ok = for {_, {:ok, r}} <- results, do: r

    failed =
      for {file, {:error, reason}} <- results,
          do: %{file: Path.basename(file), reason: inspect(reason)}

    events = Enum.reduce(ok, 0, &(&1.sent + &2))
    missing = Enum.reduce(ok, 0, fn r, acc -> acc + (r.sent - length(Enum.uniq(r.acks))) end)
    latencies = ok |> Enum.flat_map(& &1.latencies_ms) |> Enum.sort()
    durations = ok |> Enum.map(& &1.duration_ms) |> Enum.sort()

    %{
      streams: streams,
      builds_total: length(results),
      builds_ok: length(ok),
      builds_failed: length(failed),
      failures: Enum.take(failed, 20),
      events: events,
      missing_acks: missing,
      elapsed_ms: elapsed_ms,
      events_per_second: Float.round(events * 1000 / elapsed_ms, 1),
      builds_per_minute: Float.round(length(ok) * 60_000 / elapsed_ms, 1),
      ack_latency_ms: percentiles(latencies),
      build_duration_ms: percentiles(durations),
      invocations: Enum.map(ok, &%{id: &1.invocation_id, sent: &1.sent})
    }
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
    builds     #{report.builds_ok}/#{report.builds_total} ok (#{report.builds_failed} failed), #{report.builds_per_minute} builds/min over #{report.streams} streams
    events     #{report.events} sent, #{report.missing_acks} missing acks, #{report.events_per_second} events/s, #{report.elapsed_ms} ms wall
    ack ms     p50 #{lat.p50}  p90 #{lat.p90}  p99 #{lat.p99}  max #{lat.max}  (client-observed, n=#{lat.count})
    build ms   p50 #{dur.p50}  p90 #{dur.p90}  p99 #{dur.p99}  max #{dur.max}
    #{Enum.map_join(report.failures, "\\n", &"  FAILED #{&1.file}: #{&1.reason}")}
    """
  end
end
