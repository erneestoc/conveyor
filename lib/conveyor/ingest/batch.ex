defmodule Conveyor.Ingest.Batch do
  @moduledoc """
  Everything one commit writes for one invocation: the raw event segment, the log segment,
  structured upserts, and the invocation columns to set. Built by the worker, applied by a
  writer inside a group transaction.
  """

  alias Conveyor.RawStore

  @type t :: %__MODULE__{}

  defstruct ref: nil,
            invocation_id: nil,
            project_id: nil,
            day: nil,
            first_seq: 1,
            last_seq: 0,
            events: [],
            event_bytes: 0,
            # Frames acknowledged with this batch but not kept in the raw store: how many,
            # how many of them came after the last kept event, and how many the build had
            # skipped before this batch.
            skipped: 0,
            skipped_tail: 0,
            skipped_base: 0,
            log: [],
            log_bytes: 0,
            log_lines: 0,
            log_byte_offset: 0,
            log_line_offset: 0,
            targets: %{},
            tests: %{},
            actions: [],
            # Compact records of successful per-action events (`Conveyor.Rbe.StreamActions`),
            # newest first: the batch's chunk of `stream_actions`.
            stream: [],
            metrics: nil,
            invocation: %{},
            tag_keys: %{},
            waiters: [],
            finalize: false

  @spec new(String.t(), integer(), Date.t(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          t()
  def new(invocation_id, project_id, day, first_seq, log_byte_offset, log_line_offset) do
    %__MODULE__{
      ref: make_ref(),
      invocation_id: invocation_id,
      project_id: project_id,
      day: day,
      first_seq: first_seq,
      last_seq: first_seq - 1,
      log_byte_offset: log_byte_offset,
      log_line_offset: log_line_offset
    }
  end

  @doc "Records a raw BEP event (already scrubbed) at `seq`."
  @spec add_event(t(), pos_integer(), String.t(), binary()) :: t()
  def add_event(batch, seq, kind, bytes) do
    %{
      batch
      | events: [{seq, kind, bytes} | batch.events],
        event_bytes: batch.event_bytes + byte_size(bytes),
        skipped_tail: 0,
        last_seq: seq
    }
  end

  @doc """
  Records an event at `seq` that is acknowledged with this batch and normalized, but whose
  bytes are not kept (a successful per-action event of `--build_event_publish_all_actions`).
  Unlike a marker it is counted: the segment rows say how many such frames precede them.
  """
  @spec add_skipped(t(), pos_integer()) :: t()
  def add_skipped(batch, seq) do
    %{batch | skipped: batch.skipped + 1, skipped_tail: batch.skipped_tail + 1, last_seq: seq}
  end

  @doc "Sets how many frames the build had skipped before this batch (from the row)."
  @spec skipped_base(t(), non_neg_integer()) :: t()
  def skipped_base(batch, n), do: %{batch | skipped_base: n}

  @doc "Events absorbed into this batch, kept or not (what the batch limit counts)."
  @spec absorbed(t()) :: non_neg_integer()
  def absorbed(%__MODULE__{events: events, skipped: skipped}), do: length(events) + skipped

  @doc "Records a sequence number that is acknowledged with this batch but stores nothing (control messages)."
  @spec add_marker(t(), pos_integer()) :: t()
  def add_marker(batch, seq), do: %{batch | last_seq: seq}

  @spec add_log(t(), pos_integer(), String.t()) :: t()
  def add_log(batch, _seq, ""), do: batch

  def add_log(batch, seq, text) do
    lines = text |> :binary.matches("\n") |> length()

    %{
      batch
      | log: [{seq, text} | batch.log],
        log_bytes: batch.log_bytes + byte_size(text),
        log_lines: batch.log_lines + lines
    }
  end

  @spec upsert_target(t(), tuple(), map()) :: t()
  def upsert_target(batch, key, attrs),
    do: %{batch | targets: Map.update(batch.targets, key, attrs, &Map.merge(&1, attrs))}

  @spec upsert_test(t(), tuple(), map()) :: t()
  def upsert_test(batch, key, attrs),
    do: %{batch | tests: Map.update(batch.tests, key, attrs, &Map.merge(&1, attrs))}

  @spec add_action(t(), map()) :: t()
  def add_action(batch, attrs), do: %{batch | actions: [attrs | batch.actions]}

  @doc "Adds the compact record of a successful per-action event (PLAN §28)."
  @spec add_stream(t(), Conveyor.Rbe.StreamActions.action()) :: t()
  def add_stream(batch, record), do: %{batch | stream: [record | batch.stream]}

  @spec put_metrics(t(), map()) :: t()
  def put_metrics(batch, attrs), do: %{batch | metrics: Map.merge(batch.metrics || %{}, attrs)}

  @spec set_invocation(t(), map()) :: t()
  def set_invocation(batch, changes),
    do: %{batch | invocation: Map.merge(batch.invocation, changes)}

  @spec add_waiter(t(), GenServer.from(), pos_integer()) :: t()
  def add_waiter(batch, from, seq), do: %{batch | waiters: [{from, seq} | batch.waiters]}

  @spec count_tags(t(), %{String.t() => String.t()}) :: t()
  def count_tags(batch, tags) do
    %{
      batch
      | tag_keys:
          Enum.reduce(tags, batch.tag_keys, fn {k, v}, acc ->
            Map.update(acc, {k, v}, 1, &(&1 + 1))
          end)
    }
  end

  @doc """
  One batch equivalent to applying `a` then `b` for the same invocation, where `b` starts
  where `a` ended. The writer merges the batches an invocation has in one flush so the
  flush writes one segment, one log row and one fenced update for it (PLAN §24 item 1).
  Acks are still released per original batch (the worker keeps their refs).
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    unless contiguous?(a, b), do: raise(ArgumentError, "batches are not contiguous")

    %__MODULE__{
      ref: a.ref,
      invocation_id: a.invocation_id,
      project_id: a.project_id,
      day: a.day,
      first_seq: a.first_seq,
      last_seq: b.last_seq,
      # Lists are newest-first.
      events: b.events ++ a.events,
      event_bytes: a.event_bytes + b.event_bytes,
      skipped: a.skipped + b.skipped,
      skipped_tail: if(b.events == [], do: a.skipped_tail + b.skipped, else: b.skipped_tail),
      skipped_base: a.skipped_base,
      log: b.log ++ a.log,
      log_bytes: a.log_bytes + b.log_bytes,
      log_lines: a.log_lines + b.log_lines,
      log_byte_offset: a.log_byte_offset,
      log_line_offset: a.log_line_offset,
      targets: Map.merge(a.targets, b.targets, fn _k, x, y -> Map.merge(x, y) end),
      tests: Map.merge(a.tests, b.tests, fn _k, x, y -> Map.merge(x, y) end),
      actions: b.actions ++ a.actions,
      stream: b.stream ++ a.stream,
      metrics: merge_metrics(a.metrics, b.metrics),
      invocation: Map.merge(a.invocation, b.invocation),
      tag_keys: Map.merge(a.tag_keys, b.tag_keys, fn _k, x, y -> x + y end),
      waiters: b.waiters ++ a.waiters,
      finalize: a.finalize or b.finalize
    }
  end

  @doc "True when `b` continues `a` (same invocation, next sequence number)."
  @spec contiguous?(t(), t()) :: boolean()
  def contiguous?(%__MODULE__{} = a, %__MODULE__{} = b),
    do: a.invocation_id == b.invocation_id and b.first_seq == a.last_seq + 1

  @typedoc """
  The name of a unit within one group: the invocation and the unit's position among that
  invocation's units (0 for the first). Unique in the group whatever the sequences are.
  """
  @type unit_key :: {String.t(), non_neg_integer()}

  @doc """
  The units of a group of batches, in order of first appearance: each batch is merged into
  the last unit of its invocation when it continues it. A batch that does not (a resumed
  stream after a takeover, or a second worker for the build) starts a new unit, so a group
  can hold several units for one invocation; the writer keeps those in separate statements.
  Each unit comes with its key and the refs of the batches merged into it.
  """
  @spec units([t()]) :: [{unit_key(), t(), [reference()]}]
  def units(batches) do
    {units_by_id, order} =
      Enum.reduce(batches, {%{}, []}, fn b, {by_id, order} ->
        case Map.fetch(by_id, b.invocation_id) do
          {:ok, [{last, refs} | rest]} ->
            units =
              if contiguous?(last, b),
                do: [{merge(last, b), [b.ref | refs]} | rest],
                else: [{b, [b.ref]}, {last, refs} | rest]

            {Map.put(by_id, b.invocation_id, units), order}

          :error ->
            {Map.put(by_id, b.invocation_id, [{b, [b.ref]}]), [b.invocation_id | order]}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.flat_map(fn id ->
      units_by_id[id]
      |> Enum.reverse()
      |> Enum.with_index(fn {unit, refs}, n -> {{id, n}, unit, Enum.reverse(refs)} end)
    end)
  end

  @doc "The merged batches of `units/1`, without their keys."
  @spec coalesce([t()]) :: [t()]
  def coalesce(batches), do: batches |> units() |> Enum.map(&elem(&1, 1))

  defp merge_metrics(nil, m), do: m
  defp merge_metrics(m, nil), do: m
  defp merge_metrics(a, b), do: Map.merge(a, b)

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = b) do
    b.events == [] and b.log == [] and b.targets == %{} and b.tests == %{} and b.actions == [] and
      b.stream == [] and b.metrics == nil and b.invocation == %{} and b.last_seq < b.first_seq and
      b.tag_keys == %{}
  end

  @spec event_count(t()) :: non_neg_integer()
  def event_count(%__MODULE__{events: events}), do: length(events)

  @doc """
  The `event_segments` row for this batch, or nil when it holds no events. `compress` turns
  the frames into the stored payload (a writer shard passes its own compressor).
  """
  @spec event_segment_row(t(), (iodata() -> binary())) :: map() | nil
  def event_segment_row(%__MODULE__{} = b, compress \\ RawStore.compressors().bep) do
    RawStore.event_segment(
      %{
        invocation_id: b.invocation_id,
        day: b.day,
        bytes: b.event_bytes,
        # Skipped frames of the build below this row's last sequence number.
        skipped_total: b.skipped_base + b.skipped - b.skipped_tail
      },
      Enum.reverse(b.events),
      compress
    )
  end

  @doc "The `stream_actions` row for this batch, or nil when it holds no per-action record."
  @spec stream_row(t()) :: map() | nil
  def stream_row(%__MODULE__{stream: []}), do: nil

  def stream_row(%__MODULE__{} = b) do
    %{
      invocation_id: b.invocation_id,
      first_seq: b.first_seq,
      day: b.day,
      n: length(b.stream),
      records: b.stream |> Enum.reverse() |> Conveyor.Rbe.StreamActions.encode()
    }
  end

  @doc "The `log_segments` row for this batch, or nil when it holds no log text."
  @spec log_segment_row(t(), (iodata() -> binary())) :: map() | nil
  def log_segment_row(%__MODULE__{} = b, compress \\ RawStore.compressors().text) do
    RawStore.log_segment(
      %{
        invocation_id: b.invocation_id,
        day: b.day,
        byte_offset: b.log_byte_offset,
        line_offset: b.log_line_offset,
        bytes: b.log_bytes,
        lines: b.log_lines
      },
      Enum.reverse(b.log),
      compress
    )
  end
end
