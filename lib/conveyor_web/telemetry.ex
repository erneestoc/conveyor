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
    :ok = Conveyor.Histogram.attach(histograms())

    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics(), name: :conveyor_prometheus}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Prometheus exposition text: the library's counters and gauges, then our histograms."
  def scrape,
    do:
      TelemetryMetricsPrometheus.Core.scrape(:conveyor_prometheus) <> Conveyor.Histogram.scrape()

  # Up to 60 s: the client gives up at 30 s, and a histogram that ends at 1 s reads every
  # overload as "above one second".
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
    1_000_000,
    2_500_000,
    5_000_000,
    10_000_000,
    20_000_000,
    30_000_000,
    60_000_000
  ]

  @ms_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]

  @doc """
  The histograms (`Conveyor.Histogram`): fixed buckets on counters, so a node nobody
  scrapes holds no samples. No labels; a metric that needs one is a counter or a gauge.
  """
  def histograms do
    ms = System.convert_time_unit(1, :millisecond, :native)

    [
      %{
        name: "conveyor.ingest.ack.latency_us",
        event: [:conveyor, :ingest, :ack],
        measurement: :latency_us,
        buckets: @ack_buckets,
        count_as: "conveyor.ingest.ack.count",
        count_description: "Build events acknowledged after their commit",
        description:
          "Time from receiving a build event to acknowledging its commit (microseconds); resent events that were already committed are counted in conveyor_ingest_ack_resent_count instead"
      },
      %{
        name: "conveyor.ingest.writer.flush.duration",
        event: [:conveyor, :ingest, :writer, :flush],
        measurement: :duration,
        per_unit: ms,
        buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 20_000],
        description: "Group commit duration per writer shard (ms)"
      },
      %{
        name: "conveyor.ingest.writer.flush.wait",
        event: [:conveyor, :ingest, :writer, :flush],
        measurement: :wait,
        buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 20_000, 30_000],
        description:
          "How long the oldest batch of a group commit waited for its outcome, from the worker's submit (ms)"
      },
      %{
        name: "conveyor.ingest.writer.flush.events",
        event: [:conveyor, :ingest, :writer, :flush],
        measurement: :events,
        buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000],
        description: "Events per group commit"
      },
      %{
        name: "conveyor.repo.query.total_time",
        event: [:conveyor, :repo, :query],
        measurement: :total_time,
        per_unit: ms,
        buckets: @ms_buckets,
        description: "Database query time (ms)"
      },
      %{
        name: "conveyor.repo.query.queue_time",
        event: [:conveyor, :repo, :query],
        measurement: :queue_time,
        per_unit: ms,
        buckets: @ms_buckets,
        description: "Time waiting for a database connection (ms)"
      },
      %{
        name: "phoenix.endpoint.stop.duration",
        event: [:phoenix, :endpoint, :stop],
        measurement: :duration,
        per_unit: ms,
        buckets: @ms_buckets,
        description: "HTTP request duration (ms)"
      }
    ]
  end

  @doc "Metrics exported to Prometheus."
  def prometheus_metrics do
    [
      sum("conveyor.ingest.ack.resent.count",
        description:
          "Acknowledgements of resent events that were already committed (a client that retried); not in the latency histogram"
      ),
      sum("conveyor.ingest.batch.committed.events",
        description: "Build events committed to the database"
      ),
      counter("conveyor.ingest.batch.committed.count", description: "Batches committed"),
      last_value("conveyor.ingest.writer.backlog.batches",
        tags: [:shard],
        description: "Batches handed to a writer shard and not answered yet"
      ),
      last_value("conveyor.ingest.writer.backlog.bytes",
        tags: [:shard],
        description: "Event and log bytes of the batches a writer shard has not answered yet"
      ),
      last_value("conveyor.ingest.writer.backlog.oldest_ms",
        tags: [:shard],
        description:
          "Age of the oldest batch a writer shard has not answered (ms); batches expire at INGEST_WRITER_DEADLINE_MS"
      ),
      counter("conveyor.ingest.writer.group_failed.count",
        tags: [:kind],
        description:
          "Group commit attempts that failed, by kind: fenced (retried without the fenced builds), unavailable or contention (retried after a delay), data (halved)"
      ),
      sum("conveyor.ingest.writer.expired.count",
        description: "Batches that passed their deadline before their commit could start"
      ),
      last_value("conveyor.ingest.workers.count",
        description: "Live ingest workers (invocations in flight)"
      ),
      last_value("conveyor.ingest.streams.count", description: "Open BES streams"),
      last_value("conveyor.admission.state.level",
        description:
          "Admission level of the node: 0 normal, 1 elevated (keys above their share lose new builds), 2 shedding (new builds refused), 3 critical (new streams refused, events of a share of open streams refused)"
      ),
      last_value("conveyor.admission.state.pressure",
        description:
          "Commit pressure as a fraction of the writer deadline (1.0: batches expire); the levels are entered at 0.15, 0.25 and 0.75"
      ),
      last_value("conveyor.admission.state.builds_refused",
        description:
          "Share of new builds the node refuses (0-100): rises with the pressure from the shedding threshold, falls slowly"
      ),
      last_value("conveyor.admission.state.events_refused",
        description:
          "Share of open streams whose events the node refuses (0-100): above 0 only at the critical level"
      ),
      last_value("conveyor.admission.state.ready",
        description: "1 while /health/ready answers 200"
      ),
      sum("conveyor.admission.refused.count",
        tags: [:door, :reason],
        description:
          "Refusals by door (stream: at open; build: a new build at its first event or its lifecycle notification; event: the next event of an open stream) and reason (draining, overloaded, key_streams, key_share)"
      ),
      sum("conveyor.admission.slowed.count",
        description: "Events delayed because their API key was above its event rate"
      ),
      counter("conveyor.raw_log.put.count", description: "Raw-log objects written (blob mode)"),
      sum("conveyor.raw_log.put.bytes", description: "Raw-log bytes written (blob mode)"),
      counter("conveyor.raw_log.put_failed.count",
        description: "Raw-log object writes that failed"
      ),
      counter("conveyor.raw_log.sweep_failed.count",
        description: "Raw-log objects the sweep could not delete"
      ),
      last_value("conveyor.raw_log.sweep_backlog.objects",
        description:
          "Raw-log objects past their date that the sweep has not deleted yet (counted up to 100,000; 0 when the sweep keeps up)"
      ),
      last_value("conveyor.raw_log.sweep_backlog.overdue_seconds",
        description: "How long the oldest raw-log object has been past its date"
      ),
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
      counter("conveyor.raw.archived.count",
        description: "Builds whose raw events and log moved to the blob store"
      ),
      sum("conveyor.raw.archived.bytes",
        description: "Compressed bytes written to the blob store by the raw archive"
      ),
      counter("conveyor.raw_archive.failures.count",
        tags: [:reason],
        description:
          "Raw archive failures: error (retried: store or database) or mismatch (segments did not match the row; the build keeps its segments)"
      ),
      last_value("conveyor.raw_archive.overdue.seconds",
        description:
          "How long the oldest finished build has waited past RAW_ARCHIVE_AFTER_HOURS (0 when the archive is keeping up; the partition drop holds days back meanwhile)"
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

    :telemetry.execute(
      [:conveyor, :ingest, :streams],
      %{count: Conveyor.Admission.streams()},
      %{}
    )

    Conveyor.Admission.measure()
    measure_writer_backlog()
    measure_oban()
    measure_raw_archive()
    measure_raw_expiry()
  end

  # The commit pressure of every writer shard (`Conveyor.Ingest.Writer.pressure/1`).
  @doc false
  def measure_writer_backlog do
    for shard <- 0..(Conveyor.Ingest.WriterPool.shards() - 1)//1 do
      :telemetry.execute(
        [:conveyor, :ingest, :writer, :backlog],
        Conveyor.Ingest.Writer.pressure(shard),
        %{shard: shard}
      )
    end

    :ok
  end

  # One query over the days whose partitions still exist; recomputed at most once a minute
  # per node (the poller ticks every 10 s).
  @doc false
  def measure_raw_archive(now \\ System.monotonic_time(:millisecond)) do
    if Conveyor.RawStore.compaction?() do
      key = {__MODULE__, :raw_archive_overdue}

      seconds =
        case :persistent_term.get(key, nil) do
          {at, value} when now - at < 60_000 ->
            value

          _ ->
            value = Conveyor.RawStore.compaction_overdue_seconds()
            :persistent_term.put(key, {now, value})
            value
        end

      :telemetry.execute([:conveyor, :raw_archive, :overdue], %{seconds: seconds}, %{})
    end

    :ok
  rescue
    _ -> :ok
  end

  # What the raw-log sweep has not deleted yet; recomputed at most once a minute per node.
  @doc false
  def measure_raw_expiry(now \\ System.monotonic_time(:millisecond)) do
    key = {__MODULE__, :raw_expiry_backlog}

    backlog =
      case :persistent_term.get(key, nil) do
        {at, value} when now - at < 60_000 ->
          value

        _ ->
          value = Conveyor.RawStore.expiry_backlog()
          :persistent_term.put(key, {now, value})
          value
      end

    :telemetry.execute([:conveyor, :raw_log, :sweep_backlog], backlog, %{})
    :ok
  rescue
    _ -> :ok
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
end
