defmodule Conveyor.Blobs.Counting do
  @moduledoc """
  The disk adapter with its keyed-object calls counted, so a test can state what a read
  costs at the seam (ranged reads per build, per object) without looking inside the
  store. `count/1` runs a function and returns its result with the calls made meanwhile,
  by any process.
  """
  @behaviour Conveyor.Blobs.Adapter

  alias Conveyor.Blobs.Disk

  @ops [:put_object, :get_range, :delete_objects]
  @key {__MODULE__, :counters}

  @doc "Runs `fun`; returns `{result, %{put_object: n, get_range: n, delete_objects: n}}`."
  def count(fun) do
    counters = :counters.new(length(@ops), [:write_concurrency])
    :persistent_term.put(@key, counters)

    try do
      result = fun.()

      {result,
       @ops |> Enum.with_index(1) |> Map.new(fn {op, i} -> {op, :counters.get(counters, i)} end)}
    after
      :persistent_term.erase(@key)
    end
  end

  defp hit(op) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      counters -> :counters.add(counters, Enum.find_index(@ops, &(&1 == op)) + 1, 1)
    end
  end

  @impl true
  defdelegate put(digest, enum, opts), to: Disk
  @impl true
  defdelegate stream(digest, opts), to: Disk
  @impl true
  defdelegate exists?(digest, opts), to: Disk
  @impl true
  defdelegate delete(digest, opts), to: Disk

  @impl true
  def put_object(key, iodata, opts) do
    hit(:put_object)
    Disk.put_object(key, iodata, opts)
  end

  @impl true
  def get_range(key, offset, length, opts) do
    hit(:get_range)
    Disk.get_range(key, offset, length, opts)
  end

  @impl true
  def delete_objects(keys, opts) do
    hit(:delete_objects)
    Disk.delete_objects(keys, opts)
  end
end
