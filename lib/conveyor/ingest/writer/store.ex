defmodule Conveyor.Ingest.Writer.Store do
  @moduledoc """
  Where the raw bytes of a group go before its first transaction, once per group: the
  pipeline's one contact with `Conveyor.RawStore`.

  `new/4` hands the store the segments of every unit, in order, and gets back a prepared
  append; `put/1` makes the bytes durable. What that means is the store's business: in
  postgres mode the bytes stay in the rows and there is nothing to do, in blob mode
  (PLAN §25 step 2) they are laid out in one object whose key and byte ranges are fixed
  when the append is prepared. So a put that failed is tried again as the same append,
  and every transaction of the group, whichever units it still holds, writes rows of the
  one append. A unit that leaves the group (fenced, expired, failed) leaves its bytes
  where the store put them, unreferenced; the store's expiry collects them.
  """

  alias Conveyor.Ingest.Batch
  alias Conveyor.RawStore

  @type segments :: RawStore.segments()

  @opaque t ::
            {:stored, %{Batch.unit_key() => segments()}}
            | {:pending, [Batch.unit_key()], RawStore.append()}

  @doc "Prepares the append of a group's units (their segments, in `keys` order) for a shard."
  @spec new([Batch.unit_key()], %{Batch.unit_key() => segments()}, term(), boolean()) :: t()
  def new(keys, segments, shard, blob?) do
    mode = if blob?, do: :blob, else: :postgres
    {:pending, keys, RawStore.prepare(Enum.map(keys, &Map.fetch!(segments, &1)), shard, mode)}
  end

  @doc """
  Makes the bytes durable. `{:ok, store}` once they are (at once when there is nothing to
  write); `{:error, message}` when the store refused, and the same call may be made again.
  """
  @spec put(t()) :: {:ok, t()} | {:error, String.t()}
  def put({:stored, _} = store), do: {:ok, store}

  def put({:pending, keys, append}) do
    with {:ok, rows} <- RawStore.append(append) do
      {:ok, {:stored, Map.new(Enum.zip(keys, rows))}}
    end
  end

  @doc "The segment rows of the given units, as the transaction writes them (after `put/1`)."
  @spec segments(t(), [Batch.unit_key()]) :: [segments()]
  def segments({:stored, segments}, keys), do: Enum.map(keys, &Map.fetch!(segments, &1))
end
