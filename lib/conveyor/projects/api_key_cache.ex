defmodule Conveyor.Projects.ApiKeyCache do
  @moduledoc """
  ETS cache for API key lookups on the ingest hot path, with a short TTL and explicit
  invalidation. Invalidations are broadcast over PubSub so every node drops the entry.
  """
  use GenServer

  @table __MODULE__
  @topic "api_keys"
  @ttl_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the cached value for `key_id`, loading it with `loader` on a miss."
  @spec fetch(String.t(), (String.t() -> term())) :: term()
  def fetch(key_id, loader) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key_id) do
      [{^key_id, value, expires}] when expires > now ->
        value

      _ ->
        value = loader.(key_id)
        :ets.insert(@table, {key_id, value, now + @ttl_ms})
        value
    end
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(key_id) do
    :ets.delete(@table, key_id)
    Phoenix.PubSub.broadcast(Conveyor.PubSub, @topic, {:invalidate_api_key, key_id})
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Conveyor.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate_api_key, key_id}, state) do
    :ets.delete(@table, key_id)
    {:noreply, state}
  end
end
