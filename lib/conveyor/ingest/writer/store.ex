defmodule Conveyor.Ingest.Writer.Store do
  @moduledoc """
  Where the raw bytes of a group go before its first transaction, once per group.

  In postgres mode they stay in the segment rows and there is nothing to do. In blob mode
  (PLAN §25 step 2) the payloads of every unit's segments are laid out in one raw-log
  object and the rows carry their byte range; `put/1` writes that object. The layout (the
  key and every range) is fixed by `new/4`, so a put that failed is tried again under the
  same key with the same bytes, and every transaction of the group, whichever units it
  still holds, points into the one object. A unit that leaves the group (fenced, expired,
  failed) leaves its bytes in the object, unreferenced; the object goes with the sweep
  like any other.
  """

  alias Conveyor.Ingest.Batch
  alias Conveyor.RawLog

  @type segments :: {event_row :: map() | nil, log_row :: map() | nil}

  @opaque t ::
            {:stored, %{Batch.unit_key() => segments()}}
            | {:pending, %{Batch.unit_key() => segments()}, String.t(), iodata(), term()}

  @doc "Lays out the segments of a group's units (in `keys` order) for a shard."
  @spec new([Batch.unit_key()], %{Batch.unit_key() => segments()}, term(), boolean()) :: t()
  def new(keys, segments, shard, blob?) do
    rows = Enum.map(keys, &Map.fetch!(segments, &1))

    if blob? and Enum.any?(rows, &(&1 != {nil, nil})) do
      {plan, key, body} =
        RawLog.objectify(
          %{
            event_rows: for({row, _} <- rows, row != nil, do: row),
            log_rows: for({_, row} <- rows, row != nil, do: row)
          },
          shard
        )

      {:pending, zip(keys, rows, plan), key, body, shard}
    else
      {:stored, segments}
    end
  end

  @doc """
  Makes the bytes durable. `{:ok, store}` once they are (at once when there is nothing to
  write); `{:error, message}` when the object store refused, and the same call may be
  made again.
  """
  @spec put(t()) :: {:ok, t()} | {:error, String.t()}
  def put({:stored, _} = store), do: {:ok, store}

  def put({:pending, segments, key, body, shard}) do
    case RawLog.put(key, body) do
      :ok ->
        :telemetry.execute(
          [:conveyor, :raw_log, :put],
          %{count: 1, bytes: IO.iodata_length(body)},
          %{shard: shard}
        )

        {:ok, {:stored, segments}}

      {:error, reason} ->
        :telemetry.execute([:conveyor, :raw_log, :put_failed], %{count: 1}, %{shard: shard})
        {:error, "raw log put #{key} failed: #{inspect(reason)}"}
    end
  end

  @doc "The segment rows of the given units, as the transaction writes them (after `put/1`)."
  @spec segments(t(), [Batch.unit_key()]) :: [segments()]
  def segments({:stored, segments}, keys), do: Enum.map(keys, &Map.fetch!(segments, &1))

  # `RawLog.objectify/2` keeps the order of the rows it is given: hand each unit its rows
  # back.
  defp zip(keys, rows, plan) do
    {segments, {[], []}} =
      keys
      |> Enum.zip(rows)
      |> Enum.map_reduce({plan.event_rows, plan.log_rows}, fn
        {key, {event, log}}, {events, logs} ->
          {event, events} = if event, do: {hd(events), tl(events)}, else: {nil, events}
          {log, logs} = if log, do: {hd(logs), tl(logs)}, else: {nil, logs}
          {{key, {event, log}}, {events, logs}}
      end)

    Map.new(segments)
  end
end
