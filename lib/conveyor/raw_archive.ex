defmodule Conveyor.RawArchive do
  @moduledoc """
  Compaction, the third form of `Conveyor.RawStore` (callers use `RawStore.compact/2`,
  `due_for_compaction/1`): moves a finished build's raw BEP events and log out of the
  segment rows (and the raw-log objects they may point into) into the blob store, one
  object each, a day after the build finished. Every acknowledgement stays a Postgres
  commit; this only changes where history lives.

  The events object is exactly a zstd-compressed `--build_event_binary_file` (the BEP
  dictionary's id is in the frame), the log object the zstd-compressed log text. The
  store's readers prefer the blobs once the build references them; the segments stay
  until their daily partition is dropped, and the drop keeps a day that still holds a
  finished build this module has not archived (`RawStore.Expiry`).

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

  alias Conveyor.{Blobs, Repo}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.RawStore.{Codec, Expiry, Segments}
  alias Conveyor.Storage.Partitions

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
  Only builds whose partition still exists are considered. One page of `limit`; pass the
  last row of a page as `cursor` for the next (`all_due/2` walks them).
  """
  @spec candidates(DateTime.t(), pos_integer(), tuple() | nil) ::
          [{DateTime.t(), Ecto.UUID.t(), project_id :: integer()}]
  def candidates(now \\ DateTime.utc_now(), limit \\ 1000, cursor \\ nil) do
    case due_query(now) do
      nil ->
        []

      query ->
        idle_ms = Conveyor.Ingest.idle_timeout_ms()
        recent = DateTime.add(now, -2 * idle_ms, :millisecond)

        query
        |> where([i], i.updated_at < ^recent)
        |> after_cursor(cursor)
        |> order_by([i], [i.finished_at, i.id])
        |> limit(^limit)
        |> select([i], {i.finished_at, i.id, i.project_id})
        |> Repo.all()
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, id, _project_id}), do: after_cursor(query, {at, id})

  defp after_cursor(query, {at, id}),
    do: where(query, [i], i.finished_at > ^at or (i.finished_at == ^at and i.id > ^id))

  @doc """
  Every due build with its project, page by page: what an archive job is enqueued with (a
  run must not stop at one page: a fixed page per 15-minute run capped the archive at 96k
  builds a day while one node drains 20–30k an hour).
  """
  @spec all_due(DateTime.t(), pos_integer()) :: [{Ecto.UUID.t(), integer()}]
  def all_due(now \\ DateTime.utc_now(), page \\ 1000) do
    Stream.unfold(:start, fn
      :done ->
        nil

      cursor ->
        case candidates(now, page, if(cursor == :start, do: nil, else: cursor)) do
          [] -> nil
          rows when length(rows) < page -> {rows, :done}
          rows -> {rows, List.last(rows)}
        end
    end)
    |> Enum.flat_map(fn rows ->
      Enum.map(rows, fn {_at, id, project_id} -> {id, project_id} end)
    end)
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

  # Which builds are looked at and when they are due is `RawStore.Expiry`'s rule 3; the
  # window uses the index on `inserted_at`.
  defp due_query(now) do
    case Expiry.compaction_window(now, after_hours(), Partitions.oldest_day()) do
      nil ->
        nil

      {from_at, due} ->
        from i in Invocation,
          where: i.inserted_at >= ^from_at and i.inserted_at < ^due,
          where: i.raw_status == "segments" and i.stream_finished,
          where: i.status not in ["in_progress", "disconnected"],
          where: i.finished_at < ^due
    end
  end

  @doc """
  True when the partition day still holds a finished build that is not archived: the
  partition drop must keep that day (docs/spec/Archive.tla, `DropGuard`).
  """
  @spec holds_unarchived?(Date.t()) :: boolean()
  def holds_unarchived?(%Date{} = day) do
    {from_at, to_at} = Expiry.day_span(day)

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

  def archive(:gone, _now), do: {:ok, :not_found}

  def archive(id, now) when is_binary(id) do
    case Repo.get(Invocation, id) do
      nil -> {:ok, :not_found}
      inv -> archive(inv, now)
    end
  end

  defp due?(%Invocation{} = inv, now) do
    inv.stream_finished and inv.status not in ["in_progress", "disconnected"] and
      inv.finished_at != nil and
      DateTime.compare(inv.finished_at, Expiry.compaction_due_before(now, after_hours())) != :gt
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
      |> Segments.stream(:events)
      |> Stream.map(fn %{count: count, bytes: payload} ->
        data = Codec.decompress(payload)
        :counters.add(counts, 1, length(Codec.frames(data)))
        :counters.add(counts, 2, count)
        data
      end)
      |> Codec.stream(:compress, dictionary: true)

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
      |> Segments.stream(:log)
      |> Stream.map(fn %{bytes: data} ->
        text = Codec.decompress(data)
        :counters.add(counts, 1, byte_size(text))
        text
      end)
      |> Codec.stream(:compress)

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
