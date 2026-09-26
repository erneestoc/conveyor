defmodule Conveyor.RawArchive do
  @moduledoc """
  Raw write-behind: moves a finished build's raw BEP events and log out of the Postgres
  segment partitions into the blob store, one object each, a day after the build finished.
  Every acknowledgement stays a Postgres commit; this only changes where history lives.

  The events object is exactly a zstd-compressed `--build_event_binary_file` (the BEP
  dictionary's id is in the frame), the log object the zstd-compressed log text. Readers
  (`Conveyor.Invocations.raw_frames/1`, `stream_raw/1`, `stream_log/2`) prefer the blobs
  once `raw_status` is `archived`; the segments stay until their daily partition is
  dropped, and `Conveyor.Storage.Partitions.drop_before/2` keeps a day that still holds a
  finished build this module has not archived.

  Per build (`archive/1`): read the segments in order and stream them through one zstd
  context into `Conveyor.Blobs.put/3`, check the counts against the row, then in one
  transaction pin both blobs (`Blobs.pin/2` checks the object under the row lock) and
  `UPDATE … WHERE raw_status = 'segments'`. Zero rows means another node archived the
  build or retention deleted it: the blobs are discarded unless someone references them.
  A crash anywhere leaves an unreferenced blob that orphan pruning removes; the next run
  archives again. `docs/spec/Archive.tla` checks this protocol.

  Configuration (`config :conveyor, Conveyor.RawArchive`): `enabled` (`RAW_ARCHIVE_ENABLED`),
  `after_hours` (`RAW_ARCHIVE_AFTER_HOURS`, default 24).
  """
  import Ecto.Query

  require Logger

  alias Conveyor.Bep.Fixture
  alias Conveyor.{Blobs, Invocations, Repo}
  alias Conveyor.Ingest.Retry
  alias Conveyor.Invocations.{EventSegment, Invocation, LogSegment}
  alias Conveyor.Storage.Partitions

  @chunk 32

  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, false)

  @spec after_hours() :: pos_integer()
  def after_hours, do: config(:after_hours, 24)

  defp config(key, default),
    do: Application.get_env(:conveyor, __MODULE__, []) |> Keyword.get(key, default)

  @doc """
  Ids of finished builds due for archiving, oldest finish first: `raw_status` still
  `segments`, finished more than `after_hours` ago, and their row unchanged for two idle
  windows (a late finish notification or anything else touching the row waits a round).
  Only builds whose partition still exists are considered.
  """
  @spec candidates(DateTime.t(), pos_integer()) :: [Ecto.UUID.t()]
  def candidates(now \\ DateTime.utc_now(), limit \\ 1000) do
    case due_query(now) do
      nil ->
        []

      query ->
        idle_ms = Conveyor.Ingest.config(:idle_timeout_ms, 600_000)
        recent = DateTime.add(now, -2 * idle_ms, :millisecond)

        query
        |> where([i], i.updated_at < ^recent)
        |> order_by([i], i.finished_at)
        |> limit(^limit)
        |> select([i], i.id)
        |> Repo.all()
    end
  end

  @doc """
  How long the oldest due build has been waiting past `after_hours`, in seconds (0 when
  nothing is due). A value that keeps growing means the archive is not keeping up or
  failing (store outage, credentials): the partition drop is holding days back meanwhile.
  """
  @spec overdue_seconds(DateTime.t()) :: non_neg_integer()
  def overdue_seconds(now \\ DateTime.utc_now()) do
    case due_query(now) do
      nil ->
        0

      query ->
        case query |> select([i], min(i.finished_at)) |> Repo.one() do
          nil -> 0
          oldest -> max(DateTime.diff(now, oldest, :second) - after_hours() * 3600, 0)
        end
    end
  end

  # The window is bounded below by the oldest partition that still exists (the only
  # builds with segments left) and uses the index on `inserted_at`.
  defp due_query(now) do
    case oldest_partition_day() do
      nil ->
        nil

      oldest ->
        from_at = DateTime.new!(oldest, ~T[00:00:00], "Etc/UTC")
        due = DateTime.add(now, -after_hours() * 3600, :second)

        from i in Invocation,
          where: i.inserted_at >= ^from_at and i.inserted_at < ^due,
          where: i.raw_status == "segments" and i.stream_finished,
          where: i.status not in ["in_progress", "disconnected"],
          where: i.finished_at < ^due
    end
  end

  defp oldest_partition_day do
    case Partitions.partition_names("event_segments") do
      [] -> nil
      [first | _] -> Partitions.day_of("event_segments", first)
    end
  end

  @doc """
  True when the partition day still holds a finished build that is not archived: the
  partition drop must keep that day (docs/spec/Archive.tla, `DropGuard`).
  """
  @spec holds_unarchived?(Date.t()) :: boolean()
  def holds_unarchived?(%Date{} = day) do
    from_at = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    to_at = DateTime.add(from_at, 1, :day)

    Repo.exists?(
      from i in Invocation,
        where: i.inserted_at >= ^from_at and i.inserted_at < ^to_at,
        where: i.raw_status == "segments" and i.stream_finished
    )
  end

  @doc """
  Archives one build (by id, or a row loaded earlier: what another node would hold while
  this one archives it). Returns `{:ok, :archived}`, `{:ok, reason}` when there is nothing to
  do (`:not_found`, `:not_due`, `:already_archived`, `:lost` to another node,
  `:skipped` when the segments do not match the row — the build is marked and keeps its
  segments until the partition goes), or `{:error, reason}` to retry.
  """
  @spec archive(Ecto.UUID.t() | Invocation.t(), DateTime.t()) :: {:ok, atom()} | {:error, term()}
  def archive(inv_or_id, now \\ DateTime.utc_now())

  def archive(%Invocation{raw_status: "segments"} = inv, now),
    do: if(due?(inv, now), do: run(inv), else: {:ok, :not_due})

  def archive(%Invocation{}, _now), do: {:ok, :already_archived}

  def archive(id, now) when is_binary(id) do
    case Repo.get(Invocation, id) do
      nil -> {:ok, :not_found}
      inv -> archive(inv, now)
    end
  end

  defp due?(%Invocation{} = inv, now) do
    inv.stream_finished and inv.status not in ["in_progress", "disconnected"] and
      inv.finished_at != nil and
      DateTime.diff(now, inv.finished_at, :second) >= after_hours() * 3600
  end

  defp run(%Invocation{} = inv) do
    started = System.monotonic_time()

    with {:ok, events} <- put_events(inv),
         {:ok, log} <- put_log(inv),
         {:ok, outcome} <- reference(inv, events, log) do
      bytes = events.size + ((log && log.size) || 0)

      if outcome == :archived do
        :telemetry.execute(
          [:conveyor, :raw, :archived],
          %{count: 1, bytes: bytes, duration: System.monotonic_time() - started},
          %{project_id: inv.project_id}
        )
      end

      {:ok, outcome}
    else
      {:mismatch, what} -> skip(inv, what)
      {:error, reason} -> failed(inv, reason)
    end
  end

  # Segments → one compressed `--build_event_binary_file`. The frames and the rows' counts
  # must both equal the row's `event_count`, or the segments are not the whole build.
  defp put_events(%Invocation{} = inv) do
    counts = :counters.new(2, [])

    chunks =
      inv
      |> segment_rows(EventSegment, [:count, :payload])
      |> Stream.map(fn %{count: count, payload: payload} ->
        data = Invocations.decompress(payload)
        :counters.add(counts, 1, length(Fixture.frames(data)))
        :counters.add(counts, 2, count)
        data
      end)
      |> Invocations.zstd_stream(:compress, dictionary: true)

    with {:ok, blob} <-
           Blobs.put(inv.project_id, chunks,
             source: "raw",
             content_type: "application/x-bep+zstd"
           ) do
      frames = :counters.get(counts, 1)
      rows = :counters.get(counts, 2)

      if frames == inv.event_count and rows == inv.event_count and frames > 0,
        do: {:ok, blob},
        else: discard(inv, blob, {:mismatch, {:events, frames, rows, inv.event_count}})
    end
  end

  # The log text → one compressed object; none for a build without log output.
  defp put_log(%Invocation{log_bytes: 0}), do: {:ok, nil}

  defp put_log(%Invocation{} = inv) do
    counts = :counters.new(1, [])

    chunks =
      inv
      |> segment_rows(LogSegment, [:data])
      |> Stream.map(fn %{data: data} ->
        text = Invocations.decompress(data)
        :counters.add(counts, 1, byte_size(text))
        text
      end)
      |> Invocations.zstd_stream(:compress)

    with {:ok, blob} <-
           Blobs.put(inv.project_id, chunks, source: "raw", content_type: "application/zstd") do
      bytes = :counters.get(counts, 1)

      if bytes == inv.log_bytes,
        do: {:ok, blob},
        else: discard(inv, blob, {:mismatch, {:log, bytes, inv.log_bytes}})
    end
  end

  defp discard(inv, blob, result) do
    Blobs.discard(inv.project_id, blob.digest)
    result
  end

  # A few segments per query, in sequence order (keyset on first_seq), each query retried
  # on transient database errors; the partition day prunes the scan to one partition.
  defp segment_rows(%Invocation{id: id} = inv, schema, fields) do
    day = Invocations.day(inv)

    Stream.resource(
      fn -> 0 end,
      fn
        :done ->
          {:halt, :done}

        after_seq ->
          rows =
            Retry.with_backoff(
              fn ->
                Repo.all(
                  from(s in schema,
                    where: s.invocation_id == ^id and s.day == ^day and s.first_seq > ^after_seq,
                    order_by: s.first_seq,
                    limit: @chunk,
                    select: map(s, ^[:first_seq | fields])
                  ),
                  timeout: :timer.minutes(5)
                )
              end,
              label: "archive read #{id}"
            )

          case rows do
            [] -> {:halt, :done}
            rows when length(rows) < @chunk -> {rows, :done}
            rows -> {rows, List.last(rows).first_seq}
          end
      end,
      fn _ -> :ok end
    )
  end

  # Pin both blobs and point the build at them in one transaction; the conditional update
  # decides between two archivers (docs/spec/Archive.tla).
  defp reference(%Invocation{} = inv, events, log) do
    log_digest = log && log.digest

    result =
      Repo.transaction(fn ->
        with :ok <- Blobs.pin(inv.project_id, events.digest),
             :ok <- if(log_digest, do: Blobs.pin(inv.project_id, log_digest), else: :ok) do
          # No updated_at: the archive changes no reported value, and rollups treat a
          # newer updated_at as a changed hour.
          {n, _} =
            Repo.update_all(
              from(i in Invocation, where: i.id == ^inv.id and i.raw_status == "segments"),
              set: [
                raw_status: "archived",
                raw_blob: events.digest,
                log_blob: log_digest,
                raw_archived_at: DateTime.utc_now()
              ]
            )

          if n == 1, do: :archived, else: :lost
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :archived} ->
        {:ok, :archived}

      {:ok, :lost} ->
        Blobs.discard(inv.project_id, events.digest)
        if log_digest, do: Blobs.discard(inv.project_id, log_digest)
        {:ok, :lost}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp skip(%Invocation{} = inv, what) do
    Logger.warning(
      "raw archive: invocation #{inv.id} skipped, segments do not match the row: #{inspect(what)}"
    )

    Repo.update_all(
      from(i in Invocation, where: i.id == ^inv.id and i.raw_status == "segments"),
      set: [raw_status: "skipped"]
    )

    :telemetry.execute([:conveyor, :raw_archive, :failures], %{count: 1}, %{reason: :mismatch})
    {:ok, :skipped}
  end

  defp failed(%Invocation{} = inv, reason) do
    Logger.error("raw archive: invocation #{inv.id} failed: #{inspect(reason)}")
    :telemetry.execute([:conveyor, :raw_archive, :failures], %{count: 1}, %{reason: :error})
    {:error, reason}
  end
end
