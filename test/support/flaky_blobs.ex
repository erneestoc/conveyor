defmodule Conveyor.Blobs.Flaky do
  @moduledoc """
  The disk adapter with calls that fail while a switch in the application environment is
  on (`Application.put_env(:conveyor, switch, true)`):

    * `:flaky_blob_deletes` — blob deletes (a delete that cannot remove the object keeps
      the row: the object goes under the row lock, before the row);
    * `:flaky_blob_puts` — blob writes (a store outage during the raw archive);
    * `:flaky_object_puts`, `:flaky_object_reads`, `:flaky_object_deletes` — keyed objects
      (the raw log): a put that fails before the commit, a ranged read that fails under a
      reader, a sweep that cannot delete.
  """
  @behaviour Conveyor.Blobs.Adapter

  alias Conveyor.Blobs.Disk

  defp failing?(switch), do: Application.get_env(:conveyor, switch, false)

  @impl true
  def put(digest, enum, opts) do
    if failing?(:flaky_blob_puts),
      do: {:error, :store_unavailable},
      else: Disk.put(digest, enum, opts)
  end

  @impl true
  defdelegate exists?(digest, opts), to: Disk
  @impl true
  defdelegate stream(digest, opts), to: Disk

  @impl true
  def delete(digest, opts) do
    if failing?(:flaky_blob_deletes),
      do: {:error, :store_unavailable},
      else: Disk.delete(digest, opts)
  end

  @impl true
  def put_object(key, iodata, opts) do
    if failing?(:flaky_object_puts),
      do: {:error, :store_unavailable},
      else: Disk.put_object(key, iodata, opts)
  end

  @impl true
  def get_range(key, offset, length, opts) do
    if failing?(:flaky_object_reads),
      do: {:error, :store_unavailable},
      else: Disk.get_range(key, offset, length, opts)
  end

  @impl true
  def delete_objects(keys, opts) do
    if failing?(:flaky_object_deletes),
      do: {[], Enum.map(keys, &{&1, :store_unavailable})},
      else: Disk.delete_objects(keys, opts)
  end
end
