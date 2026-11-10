defmodule Conveyor.RawStore.Segments do
  @moduledoc """
  The two hot forms of a build's raw bytes, read as one: segment rows that carry their
  bytes (`event_segments.payload`, `log_segments.data`; postgres mode) and segment rows
  that carry a byte range of a raw-log object (blob mode). A build may hold both (the mode
  changed while it ran). Internal to `Conveyor.RawStore`.
  """
  import Ecto.Query

  alias Conveyor.Ingest.Retry
  alias Conveyor.Invocations
  alias Conveyor.Invocations.{EventSegment, Invocation, LogSegment}
  alias Conveyor.{RawLog, Repo}

  # Rows per query: a build of any size is read a page at a time, and the ranged reads of
  # a page are coalesced per object.
  @page 64

  @type kind :: :events | :log

  @doc """
  A build's segment rows in sequence order with their compressed bytes under `:bytes`
  (and `:first_seq`, plus `:count` for events and the offsets for the log), as a lazy
  stream: a page per query (keyset on `first_seq`, the partition day prunes the scan to
  one partition), each query retried on transient database errors.

  Options: `:from` (first `first_seq` wanted), `:upto` (last `first_seq` wanted: a
  snapshot taken earlier), `:only` (a list of `first_seq`: exactly those rows),
  `:prefetched` (byte ranges read ahead with `ranges/1` and `RawLog.prefetch/1`).
  """
  @spec stream(Invocation.t(), kind(), keyword()) :: Enumerable.t()
  def stream(%Invocation{} = inv, kind, opts \\ []) do
    {schema, col, fields} = table(kind)
    base = base(inv, schema, opts)
    prefetched = Keyword.get(opts, :prefetched, %{})

    Stream.resource(
      fn -> Keyword.get(opts, :from, 1) - 1 end,
      fn
        :done ->
          {:halt, :done}

        after_seq ->
          rows =
            Retry.with_backoff(
              fn ->
                Repo.all(
                  from(s in base,
                    where: s.first_seq > ^after_seq,
                    order_by: s.first_seq,
                    limit: @page,
                    select: map(s, ^([:first_seq, col] ++ fields ++ RawLog.object_fields()))
                  ),
                  timeout: :timer.minutes(5)
                )
              end,
              label: "raw read #{inv.id}"
            )

          case rows do
            [] -> {:halt, :done}
            rows when length(rows) < @page -> {fill(rows, col, prefetched), :done}
            rows -> {fill(rows, col, prefetched), List.last(rows).first_seq}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp fill(rows, col, prefetched) do
    rows
    |> RawLog.fetch_rows!(col, prefetched)
    |> Enum.map(fn row ->
      row |> Map.drop([col | RawLog.object_fields()]) |> Map.put(:bytes, Map.fetch!(row, col))
    end)
  end

  defp base(%Invocation{id: id} = inv, schema, opts) do
    query = from(s in schema, where: s.invocation_id == ^id and s.day == ^Invocations.day(inv))

    query =
      case Keyword.get(opts, :upto) do
        nil -> query
        upto -> where(query, [s], s.first_seq <= ^upto)
      end

    case Keyword.get(opts, :only) do
      nil -> query
      seqs -> where(query, [s], s.first_seq in ^seqs)
    end
  end

  defp table(:events), do: {EventSegment, :payload, [:count]}
  defp table(:log), do: {LogSegment, :data, [:byte_offset, :byte_size]}

  @doc """
  The byte ranges the segment rows of several builds point at, per build: what an
  object-first reader hands to `Conveyor.RawLog.prefetch/1`. Rows that carry their bytes
  have none.
  """
  @spec ranges([Invocation.t()]) :: %{
          Ecto.UUID.t() => [{String.t(), non_neg_integer(), pos_integer()}]
        }
  def ranges([]), do: %{}

  def ranges(invs) do
    ids = Enum.map(invs, & &1.id)
    days = invs |> Enum.map(&Invocations.day/1) |> Enum.uniq()

    for schema <- [EventSegment, LogSegment],
        {id, key, offset, length} <-
          Repo.all(
            from(s in schema,
              where: s.invocation_id in ^ids and s.day in ^days and not is_nil(s.object_key),
              select: {s.invocation_id, s.object_key, s.object_offset, s.object_length}
            ),
            timeout: :timer.minutes(5)
          ),
        reduce: %{} do
      acc -> Map.update(acc, id, [{key, offset, length}], &[{key, offset, length} | &1])
    end
  end

  @doc "What the rows say they hold, without their bytes: `{first_seq, last_seq, count}` per event row."
  @spec event_index(Invocation.t()) :: [{pos_integer(), pos_integer(), pos_integer()}]
  def event_index(%Invocation{} = inv) do
    Repo.all(
      from s in base(inv, EventSegment, []),
        order_by: s.first_seq,
        select: {s.first_seq, s.last_seq, s.count}
    )
  end

  @doc "The log rows' offsets, without their bytes."
  @spec log_index(Invocation.t()) :: [map()]
  def log_index(%Invocation{} = inv) do
    Repo.all(
      from s in base(inv, LogSegment, []),
        order_by: s.first_seq,
        select: map(s, [:first_seq, :byte_offset, :byte_size, :line_offset, :line_count])
    )
  end
end
