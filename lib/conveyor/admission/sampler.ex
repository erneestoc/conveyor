defmodule Conveyor.Admission.Sampler do
  @moduledoc """
  Samples the node's signals at a fixed interval, runs them through
  `Conveyor.Admission.Policy.step/4` and publishes the result in the admission cell (a few
  atomics), so that a door is a counter read and never a message to this process.

  Signals: the writer pool's commit pressure (`WriterPool.pressure/0`), the mean time
  queries waited for a connection since the last sample (from the query histogram's
  counters, no extra work per query), a `SELECT 1` probe run beside the sampler every
  `probe_ms`, and what the other nodes of the cluster report about themselves (one PubSub
  message per sample).

  The signal source and the probe are functions, replaceable at run time (`inject/1`):
  tests set the pressure they need without loading a database.
  """
  use GenServer
  require Logger

  alias Conveyor.Admission
  alias Conveyor.Admission.{Config, Policy}

  @topic "admission"
  @queue_histogram "conveyor.repo.query.queue_time"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Replaces the signal source (`signals:` a map or a function returning one), the probe
  (`probe:` a function returning `:ok | :error`) or configuration fields (`config:`), starts
  from a fresh policy state and takes one sample. `inject([])` restores the node's own.
  """
  @spec inject(keyword()) :: Policy.t()
  def inject(opts), do: GenServer.call(__MODULE__, {:inject, opts})

  @doc "Takes `n` samples now and returns the policy state."
  @spec sample(pos_integer()) :: Policy.t()
  def sample(n \\ 1), do: GenServer.call(__MODULE__, {:sample, n})

  @doc "The policy state as of the last sample."
  @spec policy() :: Policy.t()
  def policy, do: GenServer.call(__MODULE__, :policy)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Conveyor.PubSub, @topic)
    config = Config.from_env()

    state = %{
      config: config,
      base: config,
      policy: Policy.new(config),
      signals: &__MODULE__.signals/0,
      probe: &__MODULE__.probe_database/0,
      probing: nil,
      probed: nil,
      peers: %{},
      queue: {0, 0}
    }

    schedule(:sample, config.sample_ms)
    if config.probe_ms > 0, do: send(self(), :probe)
    {:ok, tick(state)}
  end

  @impl true
  def handle_call({:inject, opts}, _from, state) do
    config = struct(state.base, Keyword.get(opts, :config, []))

    state =
      %{
        state
        | config: config,
          policy: Policy.new(config),
          signals: source(Keyword.get(opts, :signals)),
          probe: Keyword.get(opts, :probe) || (&__MODULE__.probe_database/0),
          probed: nil,
          peers: %{}
      }
      |> tick()

    if config.probe_ms > 0, do: send(self(), :probe)
    {:reply, state.policy, state}
  end

  def handle_call({:sample, n}, _from, state) do
    state = Enum.reduce(1..n, state, fn _, state -> tick(state) end)
    {:reply, state.policy, state}
  end

  def handle_call(:policy, _from, state), do: {:reply, state.policy, state}

  defp source(nil), do: &__MODULE__.signals/0
  defp source(fun) when is_function(fun, 0), do: fun
  defp source(%{} = signals), do: fn -> signals end

  @impl true
  def handle_info(:sample, state) do
    schedule(:sample, state.config.sample_ms)
    {:noreply, tick(state)}
  end

  # The probe runs in its own process: a database that does not answer must not stop the
  # samples. One at a time.
  def handle_info(:probe, %{config: %{probe_ms: ms}} = state) when ms <= 0, do: {:noreply, state}

  def handle_info(:probe, %{probing: nil} = state) do
    schedule(:probe, state.config.probe_ms)
    parent = self()
    probe = state.probe
    {_pid, ref} = spawn_monitor(fn -> send(parent, {:probed, self(), probe.()}) end)
    {:noreply, %{state | probing: ref}}
  end

  def handle_info(:probe, state) do
    schedule(:probe, state.config.probe_ms)
    {:noreply, state}
  end

  def handle_info({:probed, _pid, result}, state) when result in [:ok, :error],
    do: {:noreply, %{state | probed: result}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probing: ref} = state) do
    probed = if reason == :normal, do: state.probed, else: :error
    {:noreply, %{state | probing: nil, probed: probed}}
  end

  def handle_info({:admission, node, level, db_ok}, state) do
    if node == node() do
      {:noreply, state}
    else
      peer = %{level: level, db_ok: db_ok, at: now()}
      {:noreply, %{state | peers: Map.put(state.peers, node, peer)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(_what, ms) when ms <= 0, do: :ok
  defp schedule(what, ms), do: Process.send_after(self(), what, ms)

  defp tick(state) do
    now = now()
    peers = Map.filter(state.peers, fn {_node, p} -> now - p.at <= state.config.peer_ttl_ms end)
    {queue_ms, queue} = queue_ms(state.queue)

    signals =
      %{queue_ms: queue_ms}
      |> Map.merge(state.signals.())
      |> Map.merge(%{db: state.probed, peers: Map.values(peers)})

    policy = Policy.step(state.policy, signals, now, state.config)
    Admission.publish(policy)
    announce(state.policy, policy)

    Phoenix.PubSub.broadcast_from(
      Conveyor.PubSub,
      self(),
      @topic,
      {:admission, node(), policy.level, policy.db_failures < state.config.probe_failures}
    )

    %{state | policy: policy, peers: peers, probed: nil, queue: queue}
  end

  defp announce(%{level: old} = before, %{level: new} = policy) when old != new do
    Logger.warning(
      "admission: #{Policy.name(old)} -> #{Policy.name(new)} (pressure #{Float.round(policy.pressure, 2)} of the commit deadline)"
    )

    announce(%{before | level: new}, policy)
  end

  defp announce(%{ready: old}, %{ready: new}) when old != new,
    do: Logger.warning("admission: readiness #{old} -> #{new}")

  defp announce(_before, _policy), do: :ok

  @doc false
  # The node's own signals.
  def signals do
    Conveyor.Ingest.WriterPool.pressure()
  end

  # Mean wait for a database connection over the queries since the last sample.
  defp queue_ms({last_sum, last_count}) do
    case Conveyor.Histogram.snapshot(@queue_histogram) do
      %{sum: sum, count: count} when count > last_count ->
        {max(sum - last_sum, 0) / (count - last_count), {sum, count}}

      %{sum: sum, count: count} ->
        {0, {sum, count}}

      nil ->
        {0, {last_sum, last_count}}
    end
  end

  @doc false
  def probe_database do
    case Ecto.Adapters.SQL.query(Conveyor.Repo, "SELECT 1", [], timeout: 2_000, log: false) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp now, do: System.monotonic_time(:millisecond)
end
