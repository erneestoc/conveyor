defmodule Conveyor.Blobs.Flaky do
  @moduledoc """
  The disk adapter with deletes that fail while `Application.get_env(:conveyor,
  :flaky_blob_deletes)` is true (proves a blob delete that cannot remove the object keeps
  the row: the object goes under the row lock, before the row) and writes that fail while
  `:flaky_blob_puts` is (a store outage during the raw archive).
  """
  @behaviour Conveyor.Blobs.Adapter

  alias Conveyor.Blobs.Disk

  @impl true
  def put(digest, enum, opts) do
    if Application.get_env(:conveyor, :flaky_blob_puts, false),
      do: {:error, :store_unavailable},
      else: Disk.put(digest, enum, opts)
  end

  @impl true
  defdelegate exists?(digest, opts), to: Disk
  @impl true
  defdelegate stream(digest, opts), to: Disk

  @impl true
  def delete(digest, opts) do
    if Application.get_env(:conveyor, :flaky_blob_deletes, false),
      do: {:error, :store_unavailable},
      else: Disk.delete(digest, opts)
  end
end
