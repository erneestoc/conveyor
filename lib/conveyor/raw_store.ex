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

    * **read** — `frames/1`, `bep/1`, `events_page/3`, `log/1`;
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
  alias Conveyor.RawStore.{Codec, Segments}

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
