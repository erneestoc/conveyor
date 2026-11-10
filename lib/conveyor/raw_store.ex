defmodule Conveyor.RawStore do
  @moduledoc """
  A build's raw bytes: the BEP events as Bazel sent them and the log text, from the batch
  that carries them into the database until retention removes them.

  The bytes of one build live in up to three forms over its life, and this module is the
  only one that knows which:

    1. **segment rows that carry the bytes** (`event_segments.payload`,
       `log_segments.data`): what a commit writes in postgres mode;
    2. **segment rows that carry a byte range** of a raw-log object (`object_key`,
       `object_offset`, `object_length`): what a commit writes in blob mode
       (`RAW_LOG=blob`), the object holding a whole group commit's bytes;
    3. **one archived blob per build** for the events and one for the log
       (`invocations.raw_blob`, `log_blob`, `raw_status`): what compaction leaves a day
       after the build finished.

  Callers say what they want, never where it is:

    * **append** — `prepare/3` and `append/1` for a group commit's bytes (the commit
      pipeline's store step, `Conveyor.Ingest.Writer.Store`), `event_segment/3` and
      `log_segment/3` for the rows that describe them, `write_mode/0`;
    * **read** — `frames/1`, `bep/1`, `events_page/3`, `log/1`;
    * **compact** — `compact/2` moves a finished build to form 3, `due_for_compaction/1`
      says which builds are due, `compaction_overdue_seconds/1` how late the oldest is;
    * **expire** — `expire_partitions/1` and `expire_objects/2` delete what may go at a
      given clock, `expiry_backlog/1` says what is late; the rules themselves are
      `Conveyor.RawStore.Expiry`, in one place;
    * **verify** — `audit/1`, what the persistence oracle (`Conveyor.Ingest.Verify`)
      compares against what was sent.

  The same bytes come back whatever the form: a build read before and after compaction,
  in postgres or blob mode, gives identical frames, pages and log
  (`test/conveyor/raw_store_contract_test.exs`).

  Inside: `Conveyor.RawStore.Codec` (zstd and the BEP framing), `Conveyor.RawStore.Segments`
  (forms 1 and 2), `Conveyor.RawLog` (the objects of form 2, through the blob adapter) and
  `Conveyor.RawArchive` (the move to form 3). Nothing outside this module calls them for a
  build's bytes.
  """

  alias Conveyor.Blobs
  alias Conveyor.Invocations.Invocation
  alias Conveyor.{RawArchive, RawLog}
  alias Conveyor.RawStore.{Codec, Expiry, Segments}
  alias Conveyor.Storage.Partitions

  # --- append -----------------------------------------------------------------------------

  @typedoc "The segment rows of one unit of a group commit: its events and its log, either may be absent."
  @type segments :: {event_row :: map() | nil, log_row :: map() | nil}

  @typedoc "A group's bytes, laid out and ready to be made durable (`prepare/3`, `append/1`)."
  @opaque append :: %{rows: [segments()], object: {String.t(), iodata()} | nil, shard: term()}

  @doc """
  How a node appends, read once when its writer shards start: `:postgres` (the bytes ride
  in the commit) or `{:blob, hold}` (one object per shard per `hold_ms`, sooner once
  `max_bytes` wait).
  """
  @spec write_mode() :: :postgres | {:blob, %{hold_ms: pos_integer(), max_bytes: pos_integer()}}
  def write_mode do
    if RawLog.blob_mode?(),
      do: {:blob, %{hold_ms: RawLog.flush_ms(), max_bytes: RawLog.flush_bytes()}},
      else: :postgres
  end

  @doc """
  The segment row of a unit's events (`{seq, kind, message}` in sequence order; nil when
  there are none), their messages framed and compressed by `compress` (a writer shard
  passes its own compressor, `Codec.compressors/0`).
  """
  @spec event_segment(map(), [{pos_integer(), String.t(), binary()}], (iodata() -> binary())) ::
          map() | nil
  def event_segment(_unit, [], _compress), do: nil

  def event_segment(%{invocation_id: id, day: day, bytes: bytes}, events, compress) do
    {first, _, _} = hd(events)
    {last, _, _} = List.last(events)

    %{
      invocation_id: id,
      day: day,
      first_seq: first,
      last_seq: last,
      count: length(events),
      kinds: events |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      byte_size: bytes,
      payload: compress.(Enum.map(events, fn {_seq, _kind, message} -> Codec.frame(message) end))
    }
  end

  @doc """
  The segment row of a unit's log text (`{seq, text}` chunks in order; nil when there is
  none) at the unit's position in the build's log, compressed by `compress`.
  """
  @spec log_segment(map(), [{pos_integer(), binary()}], (iodata() -> binary())) :: map() | nil
  def log_segment(_unit, [], _compress), do: nil

  def log_segment(%{invocation_id: id, day: day} = unit, chunks, compress) do
    {first, _} = hd(chunks)
    {last, _} = List.last(chunks)

    %{
      invocation_id: id,
      day: day,
      first_seq: first,
      last_seq: last,
      byte_offset: unit.byte_offset,
      line_offset: unit.line_offset,
      byte_size: unit.bytes,
      line_count: unit.lines,
      data: compress.(Enum.map(chunks, &elem(&1, 1)))
    }
  end

  @doc """
  Lays out the segments of a group commit's units (in order) for a shard. In blob mode
  this fixes the object's key and every row's byte range, so `append/1` can be retried
  and every transaction of the group writes the same rows.
  """
  @spec prepare([segments()], term(), :postgres | :blob) :: append()
  def prepare(rows, shard, mode) do
    if mode == :blob and Enum.any?(rows, &(&1 != {nil, nil})) do
      {rows, key, body} = RawLog.objectify(rows, shard)
      %{rows: rows, object: {key, body}, shard: shard}
    else
      %{rows: rows, object: nil, shard: shard}
    end
  end

  @doc """
  Makes a prepared group's bytes durable and returns the rows the commit writes, in the
  order given to `prepare/3`. An error leaves nothing a reader can see; the same append
  may be tried again (same key, same bytes). The acknowledgement must follow the commit
  of these rows, never this call alone (`docs/spec/RawLog.tla`).
  """
  @spec append(append()) :: {:ok, [segments()]} | {:error, String.t()}
  def append(%{object: nil, rows: rows}), do: {:ok, rows}

  def append(%{object: {key, body}, rows: rows, shard: shard}) do
    case RawLog.put(key, body) do
      :ok ->
        :telemetry.execute(
          [:conveyor, :raw_log, :put],
          %{count: 1, bytes: IO.iodata_length(body)},
          %{shard: shard}
        )

        {:ok, rows}

      {:error, reason} ->
        :telemetry.execute([:conveyor, :raw_log, :put_failed], %{count: 1}, %{shard: shard})
        {:error, "raw log put #{key} failed: #{inspect(reason)}"}
    end
  end

  # --- read -------------------------------------------------------------------------------

  @doc "Every BEP event of a build as its raw protobuf message, in sequence order."
  @spec frames(Invocation.t()) :: [binary()]
  def frames(%Invocation{} = inv), do: inv |> frame_stream() |> Enum.to_list()

  defp frame_stream(%Invocation{} = inv) do
    case form(inv) do
      :archived -> inv |> blob!(inv.raw_blob) |> Codec.frame_stream()
      :segments -> inv |> Segments.stream(:events) |> Stream.flat_map(&segment_frames/1)
    end
  end

  defp segment_frames(%{bytes: bytes}), do: bytes |> Codec.decompress() |> Codec.frames()

  @doc """
  The build's events as the bytes of a `--build_event_binary_file` (each message behind
  its varint length), a lazy stream of chunks: a build of any size is never held whole.
  """
  @spec bep(Invocation.t()) :: Enumerable.t()
  def bep(%Invocation{} = inv) do
    case form(inv) do
      :archived -> blob!(inv, inv.raw_blob)
      :segments -> inv |> Segments.stream(:events) |> Stream.map(&Codec.decompress(&1.bytes))
    end
  end

  @doc """
  One page of a build's events by position (the first event is 1): the raw messages with
  their positions, and how many events the build holds.
  """
  @spec events_page(Invocation.t(), pos_integer(), pos_integer()) ::
          {[{pos_integer(), binary()}], non_neg_integer()}
  def events_page(%Invocation{} = inv, page, per_page) do
    frames = frames(inv)

    events =
      frames
      |> Enum.with_index(1)
      |> Enum.slice((page - 1) * per_page, per_page)
      |> Enum.map(fn {frame, position} -> {position, frame} end)

    {events, length(frames)}
  end

  @doc """
  The build's log (stdout and stderr interleaved as received): its size in bytes and a
  lazy stream of exactly that many bytes, in order. The size is fixed when this is called,
  so a reader of a build still running can announce it (`x-log-bytes`) and splice what
  arrives later by byte offset.
  """
  @spec log(Invocation.t()) :: %{bytes: non_neg_integer(), chunks: Enumerable.t()}
  def log(%Invocation{} = inv) do
    case form(inv) do
      :archived when is_nil(inv.log_blob) -> %{bytes: 0, chunks: []}
      :archived -> %{bytes: inv.log_bytes, chunks: blob!(inv, inv.log_blob)}
      :segments -> segment_log(inv, Segments.log_index(inv))
    end
  end

  defp segment_log(_inv, []), do: %{bytes: 0, chunks: []}

  defp segment_log(inv, index) do
    %{
      bytes: index |> Enum.map(& &1.byte_size) |> Enum.sum(),
      chunks:
        inv
        |> Segments.stream(:log, upto: List.last(index).first_seq)
        |> Stream.map(&Codec.decompress(&1.bytes))
    }
  end

  # --- compact ----------------------------------------------------------------------------

  @doc "Whether finished builds are compacted on this deployment (`RAW_ARCHIVE_ENABLED`)."
  @spec compaction?() :: boolean()
  defdelegate compaction?, to: RawArchive, as: :enabled?

  @doc """
  The finished builds whose bytes are due to be compacted at `now`, oldest finish first,
  each with its project: what a compaction job is enqueued with.
  """
  @spec due_for_compaction(DateTime.t()) :: [{Ecto.UUID.t(), integer()}]
  def due_for_compaction(now \\ DateTime.utc_now()), do: RawArchive.all_due(now)

  @doc """
  How long the oldest build due for compaction has waited past its time, in seconds (0
  when none is due). A value that keeps growing means compaction is failing or not
  keeping up, and the expiry of segment partitions is being held back meanwhile.
  """
  @spec compaction_overdue_seconds(DateTime.t()) :: non_neg_integer()
  def compaction_overdue_seconds(now \\ DateTime.utc_now()), do: RawArchive.overdue_seconds(now)

  @doc """
  Compacts one build: its segments (and byte ranges) become one blob for the events and
  one for the log, and its readers switch to them in the same transaction that references
  them (`docs/spec/Archive.tla`). Takes the build's id, or the row as loaded earlier, or
  `:gone` for a build that no longer exists.

  `{:ok, :archived}`, or `{:ok, reason}` when there is nothing to do (`:not_found`,
  `:not_due`, `:already_archived`, `:lost` to another node, `:skipped` when what is
  stored does not match the row: the build is marked and keeps its segments until they
  expire), or `{:error, reason}` to try again.
  """
  @spec compact(Ecto.UUID.t() | Invocation.t() | :gone, DateTime.t()) ::
          {:ok, atom()} | {:error, term()}
  def compact(build, now \\ DateTime.utc_now()), do: RawArchive.archive(build, now)

  # --- expire -----------------------------------------------------------------------------

  @doc """
  Drops the segment partitions whose day has passed raw retention at `today`, keeping any
  day compaction has not finished with, and returns the names dropped
  (`Conveyor.RawStore.Expiry`, rule 1). Run hourly by `Workers.PartitionMaintenance`.
  """
  @spec expire_partitions(Date.t()) :: [String.t()]
  def expire_partitions(%Date{} = today \\ Date.utc_today()) do
    keep? = if compaction?(), do: &RawArchive.holds_unarchived?/1, else: fn _day -> false end
    Partitions.drop_before(Expiry.partition_cutoff(today, Expiry.raw_days()), keep?)
  end

  @doc """
  Deletes the raw-log objects no segment row can point at any more at `now`, orphans of
  failed commits included, for at most `:deadline_ms` (rule 2; bytes first, then the
  registration row). `remaining?` says the deadline ended the run with objects left. Run
  hourly by `Workers.RawLogSweep`.
  """
  @spec expire_objects(DateTime.t(), keyword()) ::
          %{deleted: non_neg_integer(), failed: non_neg_integer(), remaining?: boolean()}
  def expire_objects(%DateTime{} = now \\ DateTime.utc_now(), opts \\ []),
    do: RawLog.sweep(object_cutoff(now), opts)

  @doc """
  What `expire_objects/2` has not deleted yet at `now`: how many objects are past their
  date (counted up to 100,000) and by how many seconds the oldest is.
  """
  @spec expiry_backlog(DateTime.t()) ::
          %{objects: non_neg_integer(), overdue_seconds: non_neg_integer()}
  def expiry_backlog(%DateTime{} = now \\ DateTime.utc_now()),
    do: RawLog.sweep_backlog(object_cutoff(now))

  defp object_cutoff(now),
    do: Expiry.object_cutoff(now, Expiry.raw_days(), Partitions.oldest_day())

  # --- verify -----------------------------------------------------------------------------

  @typedoc """
  What the store holds for a build: `frames` events that decode out of it, `events` it
  says it holds, `log_bytes` of log text that read out of it, and `problems` with how it
  is stored (gaps or overlaps between pieces).
  """
  @type audit :: %{
          frames: non_neg_integer(),
          events: non_neg_integer(),
          log_bytes: non_neg_integer(),
          problems: [tuple()]
        }

  @doc "Reads everything the store holds for a build and reports it (for the oracle)."
  @spec audit(Invocation.t()) :: audit()
  def audit(%Invocation{} = inv) do
    frames = inv |> frame_stream() |> Enum.count()
    log_bytes = Enum.reduce(log(inv).chunks, 0, &(byte_size(&1) + &2))

    case form(inv) do
      # One object per kind: contiguous by construction.
      :archived ->
        %{frames: frames, events: frames, log_bytes: log_bytes, problems: []}

      :segments ->
        events = Segments.event_index(inv)
        logs = Segments.log_index(inv)

        problems =
          [
            {contiguous?(events), {:segments_not_contiguous, events}},
            {log_chain?(logs), {:log_offsets_broken, logs}}
          ]
          |> Enum.reject(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        %{
          frames: frames,
          events: events |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
          log_bytes: log_bytes,
          problems: problems
        }
    end
  end

  # Event rows cover 1..N without gaps or overlaps.
  defp contiguous?(segments) do
    segments
    |> Enum.reduce_while(1, fn {first, last, count}, expected ->
      if first == expected and last >= first and count == last - first + 1,
        do: {:cont, last + 1},
        else: {:halt, :broken}
    end)
    |> then(&(&1 != :broken))
  end

  # Log rows chain: each starts at the byte and line where the one before ended.
  defp log_chain?(logs) do
    logs
    |> Enum.reduce_while({0, 0}, fn row, {bytes, lines} ->
      if row.byte_offset == bytes and row.line_offset == lines,
        do: {:cont, {bytes + row.byte_size, lines + row.line_count}},
        else: {:halt, :broken}
    end)
    |> then(&(&1 != :broken))
  end

  # --- forms ------------------------------------------------------------------------------

  # Archived means the events blob is referenced; until then the segments are the build.
  defp form(%Invocation{raw_status: "archived", raw_blob: blob}) when is_binary(blob),
    do: :archived

  defp form(%Invocation{}), do: :segments

  # A blob that is gone from the store reads as an error, never as an empty build.
  defp blob!(%Invocation{project_id: project_id}, digest) do
    case Blobs.stream(project_id, digest, chunk_size: 256 * 1024) do
      {:ok, chunks} -> Codec.stream(chunks, :decompress)
      {:error, reason} -> raise "blob #{digest} of an archived build: #{inspect(reason)}"
    end
  end
end
