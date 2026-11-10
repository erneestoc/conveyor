defmodule Conveyor.HistogramTest do
  # The histograms are node-wide (one set of counters), so this module is not async.
  use ExUnit.Case, async: false

  alias Conveyor.Histogram

  @ack [:conveyor, :ingest, :ack]

  setup do
    Histogram.reset()
    :ok
  end

  test "samples that nobody scrapes take no memory" do
    table = :conveyor_prometheus_dist
    rows = :ets.info(table, :size)
    words = :erlang.memory(:total)

    for _ <- 1..20_000 do
      :telemetry.execute(@ack, %{latency_us: 1234, count: 1}, %{})
      :telemetry.execute([:conveyor, :repo, :query], %{total_time: 5_000, queue_time: 10}, %{})

      :telemetry.execute(
        [:conveyor, :ingest, :writer, :flush],
        %{duration: 1_000, wait: 10, events: 5, batches: 1},
        %{shard: 0}
      )
    end

    # 100,000 samples used to be 100,000 rows (about 190 bytes each) until a scrape.
    assert :ets.info(table, :size) - rows < 100
    assert :erlang.memory(:total) - words < 4_000_000
    assert %{count: 20_000} = Histogram.snapshot("conveyor.ingest.ack.latency_us")
  end

  test "buckets are cumulative, the sum is in the exported unit, bounds are inclusive" do
    for us <- [50, 100, 101, 999_999, 30_000_000, 90_000_000],
        do: :telemetry.execute(@ack, %{latency_us: us, count: 1}, %{})

    %{buckets: buckets, count: 6, sum: sum} = Histogram.snapshot("conveyor.ingest.ack.latency_us")
    assert sum == 50 + 100 + 101 + 999_999 + 30_000_000 + 90_000_000
    assert {100, 2} = List.keyfind(buckets, 100, 0)
    assert {250, 3} = List.keyfind(buckets, 250, 0)
    assert {1_000_000, 4} = List.keyfind(buckets, 1_000_000, 0)
    # The histogram covers the client's 30 s timeout and beyond.
    assert {30_000_000, 5} = List.keyfind(buckets, 30_000_000, 0)
    assert {60_000_000, 5} = List.keyfind(buckets, 60_000_000, 0)
    assert {"+Inf", 6} = List.last(buckets)

    ms = System.convert_time_unit(1, :millisecond, :native)

    :telemetry.execute(
      [:conveyor, :ingest, :writer, :flush],
      %{duration: 7 * ms, wait: 30, events: 12.0, batches: 1},
      %{shard: 0}
    )

    assert %{count: 1, sum: 7.0, buckets: flush} =
             Histogram.snapshot("conveyor.ingest.writer.flush.duration")

    assert {5, 0} = List.keyfind(flush, 5, 0)
    assert {10, 1} = List.keyfind(flush, 10, 0)
    assert %{count: 1, sum: 12} = Histogram.snapshot("conveyor.ingest.writer.flush.events")
    assert Histogram.snapshot("nope") == nil
  end

  test "the exposition text keeps the library's names and shape" do
    :telemetry.execute(@ack, %{latency_us: 300, count: 1}, %{})
    # A query that did not queue carries no queue time.
    :telemetry.execute([:conveyor, :repo, :query], %{total_time: 5_000, queue_time: nil}, %{})
    Histogram.observe("conveyor.repo.query.queue_time", 0)
    text = ConveyorWeb.Telemetry.scrape()

    assert text =~ "# TYPE conveyor_ingest_ack_latency_us histogram\n"
    assert text =~ ~s(conveyor_ingest_ack_latency_us_bucket{le="250"} 0\n)
    assert text =~ ~s(conveyor_ingest_ack_latency_us_bucket{le="500"} 1\n)
    assert text =~ ~s(conveyor_ingest_ack_latency_us_bucket{le="+Inf"} 1\n)
    assert text =~ "conveyor_ingest_ack_latency_us_sum 300\n"
    assert text =~ "conveyor_ingest_ack_latency_us_count 1\n"
    assert text =~ ~s(conveyor_repo_query_queue_time_bucket{le="1"} 1\n)
    assert text =~ "conveyor_repo_query_total_time_count 1\n"
    assert text =~ "# TYPE phoenix_endpoint_stop_duration histogram"
    # Counters and gauges still come from the library.
    assert text =~ "# TYPE conveyor_ingest_ack_count counter"
  end

  test "attaching again keeps the counts" do
    :telemetry.execute(@ack, %{latency_us: 300, count: 1}, %{})
    :ok = Histogram.attach(ConveyorWeb.Telemetry.histograms())
    :telemetry.execute(@ack, %{latency_us: 300, count: 1}, %{})
    assert %{count: 2} = Histogram.snapshot("conveyor.ingest.ack.latency_us")
  end
end
