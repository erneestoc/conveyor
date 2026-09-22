defmodule Conveyor.Ingest.Batch do
  @moduledoc """
  Everything one commit writes for one invocation: the raw event segment, the log segment,
  structured upserts, and the invocation columns to set. Built by the worker, applied by a
  writer inside a group transaction.
  """

  alias Conveyor.Bep.Fixture
  alias Conveyor.Invocations

  @type t :: %__MODULE__{}

  defstruct ref: nil,
            invocation_id: nil,
            project_id: nil,
            day: nil,
            first_seq: 1,
            last_seq: 0,
            events: [],
            event_bytes: 0,
            log: [],
            log_bytes: 0,
            log_lines: 0,
            log_byte_offset: 0,
            log_line_offset: 0,
            targets: %{},
            tests: %{},
            actions: [],
            named_sets: [],
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
        last_seq: seq
    }
  end

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

  @spec add_named_set(t(), map()) :: t()
  def add_named_set(batch, attrs), do: %{batch | named_sets: [attrs | batch.named_sets]}

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
      log: b.log ++ a.log,
      log_bytes: a.log_bytes + b.log_bytes,
      log_lines: a.log_lines + b.log_lines,
      log_byte_offset: a.log_byte_offset,
      log_line_offset: a.log_line_offset,
      targets: Map.merge(a.targets, b.targets, fn _k, x, y -> Map.merge(x, y) end),
      tests: Map.merge(a.tests, b.tests, fn _k, x, y -> Map.merge(x, y) end),
      actions: b.actions ++ a.actions,
      named_sets: b.named_sets ++ a.named_sets,
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

  @doc """
  Merges each batch into the last unit of its invocation when it continues it, keeping the
  units in order of first appearance. A non-contiguous batch of one invocation (a resumed
  stream after a takeover) starts a new unit, so a flush can hold two units for one
  invocation; the writer keeps those in separate statements.
  """
  @spec coalesce([t()]) :: [t()]
  def coalesce(batches) do
    {units_by_id, order} =
      Enum.reduce(batches, {%{}, []}, fn b, {by_id, order} ->
        case Map.fetch(by_id, b.invocation_id) do
          {:ok, [last | rest]} ->
            units = if contiguous?(last, b), do: [merge(last, b) | rest], else: [b, last | rest]
            {Map.put(by_id, b.invocation_id, units), order}

          :error ->
            {Map.put(by_id, b.invocation_id, [b]), [b.invocation_id | order]}
        end
      end)

    order |> Enum.reverse() |> Enum.flat_map(&Enum.reverse(units_by_id[&1]))
  end

  defp merge_metrics(nil, m), do: m
  defp merge_metrics(m, nil), do: m
  defp merge_metrics(a, b), do: Map.merge(a, b)

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = b) do
    b.events == [] and b.log == [] and b.targets == %{} and b.tests == %{} and b.actions == [] and
      b.named_sets == [] and b.metrics == nil and b.invocation == %{} and b.last_seq < b.first_seq and
      b.tag_keys == %{}
  end

  @spec event_count(t()) :: non_neg_integer()
  def event_count(%__MODULE__{events: events}), do: length(events)

  @doc "The `event_segments` row for this batch, or nil when it holds no events."
  @spec event_segment_row(t()) :: map() | nil
  def event_segment_row(%__MODULE__{events: []}), do: nil

  def event_segment_row(%__MODULE__{} = b) do
    events = Enum.reverse(b.events)

    frames =
      Enum.map(events, fn {_seq, _kind, bytes} ->
        [Fixture.encode_varint(byte_size(bytes)), bytes]
      end)

    {first, _, _} = hd(events)
    {last, _, _} = List.last(events)

    %{
      invocation_id: b.invocation_id,
      day: b.day,
      first_seq: first,
      last_seq: last,
      count: length(events),
      kinds: events |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      byte_size: b.event_bytes,
      payload: Invocations.compress(frames)
    }
  end

  @doc "The `log_segments` row for this batch, or nil when it holds no log text."
  @spec log_segment_row(t()) :: map() | nil
  def log_segment_row(%__MODULE__{log: []}), do: nil

  def log_segment_row(%__MODULE__{} = b) do
    chunks = Enum.reverse(b.log)
    {first, _} = hd(chunks)
    {last, _} = List.last(chunks)

    %{
      invocation_id: b.invocation_id,
      day: b.day,
      first_seq: first,
      last_seq: last,
      byte_offset: b.log_byte_offset,
      line_offset: b.log_line_offset,
      byte_size: b.log_bytes,
      line_count: b.log_lines,
      data: Invocations.compress(Enum.map(chunks, &elem(&1, 1)))
    }
  end
end
