defmodule Conveyor.Blobs.OneShot do
  @moduledoc """
  The disk adapter with streams that can be enumerated once, the way the S3 adapter's
  temp-file streams behave: a second enumeration raises. Tests switch the blob store to it
  to prove that nothing reads a response stream twice.
  """
  @behaviour Conveyor.Blobs.Adapter

  alias Conveyor.Blobs.Disk

  @impl true
  defdelegate put(digest, enum, opts), to: Disk
  @impl true
  defdelegate exists?(digest, opts), to: Disk
  @impl true
  defdelegate delete(digest, opts), to: Disk

  @impl true
  def stream(digest, opts) do
    with {:ok, inner} <- Disk.stream(digest, opts) do
      used = :counters.new(1, [])

      {:ok,
       Stream.resource(
         fn ->
           if :counters.get(used, 1) > 0, do: raise("one-shot stream enumerated twice")
           :counters.add(used, 1, 1)
           inner
         end,
         fn
           nil -> {:halt, nil}
           inner -> {Enum.to_list(inner), nil}
         end,
         fn _ -> :ok end
       )}
    end
  end
end
