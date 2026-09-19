defmodule ConveyorWeb.Telemetry do
  @moduledoc """
  Telemetry metrics for LiveDashboard and Prometheus (`GET /metrics`). The ingest metrics
  are the ones the scale campaign (M7) watches: ack latency, events and batches committed,
  active streams and workers.
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics(), name: :conveyor_prometheus}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Prometheus exposition text."
  def scrape, do: TelemetryMetricsPrometheus.Core.scrape(:conveyor_prometheus)

  @ack_buckets [
    100,
    250,
    500,
    1_000,
    2_500,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000
  ]

  @doc "Metrics exported to Prometheus."
  def prometheus_metrics do
    [
      distribution("conveyor.ingest.ack.latency_us",
        description: "Time from receiving a build event to acknowledging it (microseconds)",
        reporter_options: [buckets: @ack_buckets]
      ),
      counter("conveyor.ingest.ack.count", description: "Build events acknowledged"),
      sum("conveyor.ingest.batch.committed.events",
        description: "Build events committed to the database"
      ),
      counter("conveyor.ingest.batch.committed.count", description: "Batches committed"),
      distribution("conveyor.ingest.writer.flush.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]],
        description: "Group commit duration per writer shard (ms)"
      ),
      distribution("conveyor.ingest.writer.flush.events",
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]],
        description: "Events per group commit"
      ),
      last_value("conveyor.ingest.workers.count",
        description: "Live ingest workers (invocations in flight)"
      ),
      last_value("conveyor.ingest.streams.count", description: "Open BES streams"),
      distribution("conveyor.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]],
        description: "Database query time (ms)"
      ),
      distribution("conveyor.repo.query.queue_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]],
        description: "Time waiting for a database connection (ms)"
      ),
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]],
        description: "HTTP request duration (ms)"
      ),
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.system_counts.process_count")
    ]
  end

  @doc "Metrics for Phoenix LiveDashboard (development)."
  def metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("conveyor.repo.query.total_time", unit: {:native, :millisecond}),
      summary("conveyor.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("conveyor.ingest.ack.latency_us"),
      sum("conveyor.ingest.batch.committed.events"),
      last_value("conveyor.ingest.workers.count"),
      last_value("conveyor.ingest.streams.count"),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_ingest, []}
    ]
  end

  @doc false
  def measure_ingest do
    :telemetry.execute([:conveyor, :ingest, :workers], %{count: workers()}, %{})
    :telemetry.execute([:conveyor, :ingest, :streams], %{count: streams()}, %{})
  end

  # The poller can fire before the ingest supervision tree is up.
  defp workers do
    Registry.count(Conveyor.Ingest.Registry)
  rescue
    ArgumentError -> 0
  end

  defp streams do
    Conveyor.Limits.total_streams()
  rescue
    ArgumentError -> 0
  end
end
