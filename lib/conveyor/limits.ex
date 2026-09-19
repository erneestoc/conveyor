defmodule Conveyor.Limits do
  @moduledoc """
  Per-API-key ingest limits, enforced without a database round trip:

    * `max_streams` — concurrent BES streams per key (`RESOURCE_EXHAUSTED` beyond it)
    * `max_events_per_second` — token bucket per key; senders above it are slowed down
      by delaying their events (never failed)
    * `max_log_bytes` — build log bytes per invocation; the rest is dropped with a marker

  Defaults come from `config :conveyor, Conveyor.Limits`; a key's `limits` map overrides
  them (`"max_streams"`, `"max_events_per_second"`, `"max_log_bytes"`). Counters live in
  a public ETS table owned by this process, so they are per node (M7 shares nothing).
  """
  use GenServer

  @table __MODULE__

  @type limits :: %{
          max_streams: pos_integer(),
          max_events_per_second: pos_integer(),
          max_log_bytes: pos_integer()
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{refs: %{}}}
  end

  # Stream slots are handed out by this process so that a monitor on the stream handler
  # releases the slot even when the connection drops and the handler is killed.
  @impl true
  def handle_call({:acquire, key_id, max, pid}, _from, state) do
    count = streams(key_id)

    if count >= max do
      {:reply, {:error, :too_many_streams}, state}
    else
      :ets.insert(@table, {{:streams, key_id}, count + 1})
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | refs: Map.put(state.refs, ref, {key_id, pid})}}
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.refs, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{state | refs: %{}}}
  end

  @impl true
  def handle_cast({:release, key_id, pid}, state) do
    case Enum.find(state.refs, fn {_ref, {k, p}} -> k == key_id and p == pid end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        {:noreply, decrement(state, ref)}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, decrement(state, ref)}

  defp decrement(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        state

      {{key_id, _pid}, refs} ->
        :ets.update_counter(@table, {:streams, key_id}, {2, -1, 0, 0}, {{:streams, key_id}, 0})
        %{state | refs: refs}
    end
  end

  def config(key, default \\ nil),
    do: Application.get_env(:conveyor, __MODULE__, []) |> Keyword.get(key, default)

  @doc "The configured defaults."
  @spec defaults() :: limits()
  def defaults do
    %{
      max_streams: config(:max_streams_per_key, 200),
      max_events_per_second: config(:max_events_per_second_per_key, 5_000),
      max_log_bytes: config(:max_log_bytes, 256 * 1024 * 1024)
    }
  end

  @doc "Defaults overridden by a key's `limits` map."
  @spec for_key(map() | nil) :: limits()
  def for_key(nil), do: defaults()

  def for_key(%{limits: overrides}) when is_map(overrides) do
    Enum.reduce(defaults(), %{}, fn {k, default}, acc ->
      case Map.get(overrides, Atom.to_string(k)) do
        n when is_integer(n) and n > 0 -> Map.put(acc, k, n)
        _ -> Map.put(acc, k, default)
      end
    end)
  end

  def for_key(_), do: defaults()

  @doc """
  Registers the calling process as a stream for the key; fails when the key is at its
  concurrent-stream limit. The slot is released by `release_stream/1` or when the
  caller exits.
  """
  @spec acquire_stream(term(), limits()) :: :ok | {:error, :too_many_streams}
  def acquire_stream(nil, _limits), do: :ok

  def acquire_stream(key_id, %{max_streams: max}),
    do: GenServer.call(__MODULE__, {:acquire, key_id, max, self()})

  @spec release_stream(term()) :: :ok
  def release_stream(nil), do: :ok
  def release_stream(key_id), do: GenServer.cast(__MODULE__, {:release, key_id, self()})

  @doc "Current concurrent stream count for a key."
  @spec streams(term()) :: non_neg_integer()
  def streams(key_id) do
    case :ets.lookup(@table, {:streams, key_id}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @doc """
  Takes one event token for the key, sleeping in small steps while the bucket is empty.
  Senders above their rate are slowed down rather than failed: a failed BES stream makes
  Bazel resend everything, which is the opposite of what a rate limit wants.
  """
  @spec throttle(term(), limits()) :: :ok
  def throttle(nil, _limits), do: :ok

  def throttle(key_id, %{max_events_per_second: rate}) do
    if take_token(key_id, rate) do
      :ok
    else
      Process.sleep(10)
      throttle(key_id, %{max_events_per_second: rate})
    end
  end

  # Token bucket with capacity = rate, refilled continuously; stored as {tokens, last_ms}.
  # The bucket row is replaced atomically enough for our purposes (contention only costs a
  # token miscount within one millisecond).
  defp take_token(key_id, rate) do
    now = System.monotonic_time(:millisecond)

    {tokens, last} =
      case :ets.lookup(@table, {:bucket, key_id}) do
        [{_, tokens, last}] -> {tokens, last}
        [] -> {rate * 1.0, now}
      end

    tokens = min(rate * 1.0, tokens + (now - last) * rate / 1000)

    if tokens >= 1 do
      :ets.insert(@table, {{:bucket, key_id}, tokens - 1, now})
      true
    else
      :ets.insert(@table, {{:bucket, key_id}, tokens, now})
      false
    end
  end

  @doc "Concurrent streams across all keys on this node."
  @spec total_streams() :: non_neg_integer()
  def total_streams do
    :ets.select(@table, [{{{:streams, :_}, :"$1"}, [], [:"$1"]}]) |> Enum.sum()
  end

  @doc "Clears all counters (tests)."
  def reset do
    :ets.delete_all_objects(@table)
    GenServer.call(__MODULE__, :reset)
  end
end
