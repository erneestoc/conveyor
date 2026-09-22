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
      counter("conveyor.ingest.fenced.count",
        description: "Batch commits fenced by another node's write to the same invocation"
      ),
      counter("conveyor.blobs.errors.count",
        tags: [:op],
        description: "Blob store (disk or S3) failures by operation"
      ),
      last_value("conveyor.oban.jobs.count",
        tags: [:queue, :state],
        description: "Oban jobs per queue and state"
      ),
      last_value("conveyor.oban.oldest_available.seconds",
        tags: [:queue],
        description:
          "Age of the oldest job waiting in the queue (a backlog that only grows means the queue is not being drained: alert above 600)"
      ),
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
    measure_oban()
  end

  @oban_states ~w(available scheduled executing retryable)

  # Job counts per queue and state plus the age of the oldest waiting job, so a queue that
  # stops draining (the trial's stalled parse jobs) is an alert, not a discovery.
  @doc false
  def measure_oban do
    import Ecto.Query

    counts =
      Conveyor.Repo.all(
        from j in Oban.Job,
          where: j.state in ^@oban_states,
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
      )
      |> Map.new(fn {queue, state, n} -> {{queue, state}, n} end)

    for queue <- queues(), state <- @oban_states do
      :telemetry.execute(
        [:conveyor, :oban, :jobs],
        %{count: Map.get(counts, {queue, state}, 0)},
        %{queue: queue, state: state}
      )
    end

    oldest =
      Conveyor.Repo.all(
        from j in Oban.Job,
          where: j.state == "available" and j.scheduled_at <= ^DateTime.utc_now(),
          group_by: j.queue,
          select: {j.queue, min(j.scheduled_at)}
      )
      |> Map.new()

    for queue <- queues() do
      age =
        case Map.get(oldest, queue) do
          nil -> 0
          at -> max(DateTime.diff(DateTime.utc_now(), at, :second), 0)
        end

      :telemetry.execute([:conveyor, :oban, :oldest_available], %{seconds: age}, %{queue: queue})
    end

    :ok
  rescue
    # Before the repo is up, or without a database (release tasks).
    _ -> :ok
  end

  defp queues do
    Application.get_env(:conveyor, Oban, [])
    |> Keyword.get(:queues, [])
    |> Enum.map(fn {queue, _} -> Atom.to_string(queue) end)
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
