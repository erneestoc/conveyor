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
