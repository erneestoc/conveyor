defmodule Conveyor.Admission do
  @moduledoc """
  Admission: whether this node takes more work. One module answers "accept, slow down or
  refuse" at three doors, from the per-key quotas, the drain flag and the node's commit
  pressure.

  | Door | Call | Refused with |
  |---|---|---|
  | a new stream (gRPC, the HTTP upload, `Ingest.push_all/3`) | `open_stream/2`, then `build/2` once the first event names the build | UNAVAILABLE / 503 (draining, overloaded, key above its share), RESOURCE_EXHAUSTED / 429 (key at its stream limit) |
  | the next event of an open stream | `event/1` | UNAVAILABLE / 503; a key above its event rate is slowed down, never refused |
  | readiness (`/health/ready`) | `ready/0` | |

  The decisions are `Conveyor.Admission.Policy` (pure). `Conveyor.Admission.Sampler` feeds it
  the signals every 250 ms and publishes the outcome in a few atomics, so the event door is
  one counter read and a comparison; `Conveyor.Limits` keeps the per-key counters. What a
  refusal promises: the refused call wrote nothing and acknowledged nothing. A refused
  stream took no slot and started no session; a refused event was never handed to its
  session, so it is never acknowledged, and the client resends it.

  Draining (`drain/1`) is the same door: a draining node refuses new streams and reports
  not ready while open streams finish.
  """
  require Logger

  alias Conveyor.Admission.Policy
  alias Conveyor.Limits

  @cell {__MODULE__, :cell}
  # Slots of the cell.
  @level 1
  @events_pct 2
  @draining 3
  @ready 4
  @database 5
  @share 6
  @pressure 7

  @typedoc "What an open stream holds: its key, the key's limits and its shedding bucket."
  @opaque ticket :: {term(), Limits.limits(), 0..99, :atomics.atomics_ref()}
  @type refusal :: {:refuse, Policy.reason()}

  # --- the stream door ----------------------------------------------------------------------

  @doc """
  A stream is opened for `key_id` (`nil` without API keys). Takes a slot of the key, held
  until `close_stream/1` or the death of the calling process.
  """
  @spec open_stream(term(), Limits.limits() | nil) :: {:ok, ticket()} | refusal()
  def open_stream(key_id, limits \\ nil) do
    limits = limits || Limits.defaults()
    max = if key_id == nil, do: :infinity, else: limits.max_streams
    request = %{draining?: draining?(), key_streams: Limits.streams(key_id), max_streams: max}

    with :accept <- Policy.decide(:stream, snapshot(), request),
         :ok <- Limits.acquire_stream(key_id, limits) do
      {:ok, {key_id, limits, :erlang.unique_integer([:positive]) |> rem(100), cell()}}
    else
      {:error, :too_many_streams} -> refused(:stream, :key_streams)
      {:refuse, reason} -> refused(:stream, reason)
    end
  end

  @doc "Gives the stream's slot back."
  @spec close_stream(ticket()) :: :ok
  def close_stream({key_id, _limits, _bucket, _cell}), do: Limits.release_stream(key_id)

  @doc """
  The build a stream (or a lifecycle notification) belongs to is known. `resumed?` says the
  build already has events here or elsewhere: under pressure a build in progress is kept
  and a new one is refused first.
  """
  @spec build(ticket() | term(), boolean()) :: :ok | refusal()
  def build({key_id, _limits, _bucket, _cell}, resumed?), do: build(key_id, resumed?)

  def build(key_id, resumed?) do
    cell = cell()

    case :atomics.get(cell, @level) do
      0 ->
        :ok

      level ->
        request = %{
          resumed?: resumed?,
          over_share?: Limits.streams(key_id) > :atomics.get(cell, @share)
        }

        case Policy.decide(:build, %{level: level, events_pct: 0}, request) do
          :accept -> :ok
          {:refuse, reason} -> refused(:build, reason)
        end
    end
  end

  # --- the event door -----------------------------------------------------------------------

  @doc """
  The next event of an open stream. Returns once the event may be handed to its session:
  at once, or after a wait when the key is above its event rate (slowed down, never failed:
  a failed stream makes Bazel resend everything).
  """
  @spec event(ticket()) :: :ok | refusal()
  def event({key_id, limits, bucket, cell}) do
    # `Policy.decide(:event, …)` spelled out for the path every event takes: one counter
    # read and a comparison, then the key's token (`policy_test.exs` holds the table, and
    # `admission_test.exs` that this agrees with it).
    cond do
      :atomics.get(cell, @events_pct) > bucket -> refused(:event, :overloaded)
      key_id == nil -> :ok
      Limits.take_token(key_id, limits.max_events_per_second) -> :ok
      true -> slow(key_id, limits.max_events_per_second)
    end
  end

  defp slow(key_id, rate) do
    :telemetry.execute([:conveyor, :admission, :slowed], %{count: 1}, %{})
    wait_for_token(key_id, rate)
  end

  defp wait_for_token(key_id, rate) do
    {:slow, ms} = Policy.decide(:event, %{events_pct: 0}, %{bucket: 0, token?: false})
    Process.sleep(ms)
    if Limits.take_token(key_id, rate), do: :ok, else: wait_for_token(key_id, rate)
  end

  defp refused(door, reason) do
    :telemetry.execute([:conveyor, :admission, :refused], %{count: 1}, %{
      door: door,
      reason: reason
    })

    {:refuse, reason}
  end

  # --- readiness and state ------------------------------------------------------------------

  @doc "Whether a balancer should send this node new connections, and why not."
  @spec ready() :: %{ready: boolean(), state: atom(), checks: map()}
  def ready do
    s = state()

    %{
      ready: s.ready and not s.draining,
      state: s.state,
      checks: %{database: s.database, draining: s.draining, overloaded: s.level >= 2}
    }
  end

  @doc "The admission state of this node, as of the last sample."
  @spec state() :: map()
  def state do
    cell = cell()
    level = :atomics.get(cell, @level)

    %{
      level: level,
      state: Policy.name(level),
      pressure: :atomics.get(cell, @pressure) / 1000,
      events_refused_pct: :atomics.get(cell, @events_pct),
      ready: :atomics.get(cell, @ready) == 1,
      database: :atomics.get(cell, @database) == 1,
      draining: :atomics.get(cell, @draining) == 1,
      streams: streams()
    }
  end

  @doc "Open streams on this node, across all keys and without one."
  @spec streams() :: non_neg_integer()
  def streams do
    Limits.total_streams()
  rescue
    # Before the counters exist (the telemetry poller starts first).
    ArgumentError -> 0
  end

  @doc "Emits the admission gauges (the telemetry poller and the scrape call it)."
  @spec measure() :: :ok
  def measure do
    s = state()

    :telemetry.execute(
      [:conveyor, :admission, :state],
      %{
        level: s.level,
        pressure: s.pressure,
        ready: if(s.ready and not s.draining, do: 1, else: 0)
      },
      %{}
    )
  end

  @doc false
  # The sampler's side of the cell.
  def publish(%Policy{} = policy) do
    cell = cell()
    {total, keys} = Limits.share()
    :atomics.put(cell, @level, policy.level)
    :atomics.put(cell, @events_pct, policy.events_pct)
    :atomics.put(cell, @ready, if(policy.ready, do: 1, else: 0))
    :atomics.put(cell, @database, if(policy.db_seen and policy.db_failures == 0, do: 1, else: 0))
    :atomics.put(cell, @share, ceil(total / max(keys, 1)))
    :atomics.put(cell, @pressure, round(policy.pressure * 1000))
  end

  defp snapshot do
    cell = cell()
    %{level: :atomics.get(cell, @level), events_pct: :atomics.get(cell, @events_pct)}
  end

  # A node is ready and its database fine until a sample says otherwise.
  defp cell do
    case :persistent_term.get(@cell, nil) do
      nil ->
        cell = :atomics.new(7, signed: false)
        :atomics.put(cell, @ready, 1)
        :atomics.put(cell, @database, 1)
        :persistent_term.put(@cell, cell)
        cell

      cell ->
        cell
    end
  end

  # --- draining -----------------------------------------------------------------------------

  @doc "Whether this node is draining."
  @spec draining?() :: boolean()
  def draining?, do: :atomics.get(cell(), @draining) == 1

  @doc """
  Graceful shutdown (`Conveyor.Application.prep_stop/1` on SIGTERM): new streams are refused
  with UNAVAILABLE, readiness turns 503 so balancers stop routing here, and the call waits
  until no stream is open or `timeout_ms` has passed.
  """
  @spec drain(non_neg_integer()) :: :ok | :timeout
  def drain(timeout_ms) do
    :atomics.put(cell(), @draining, 1)

    Logger.info(
      "draining: refusing new streams, waiting up to #{timeout_ms} ms for #{streams()} open streams"
    )

    wait(System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc "Takes new streams again (tests)."
  @spec resume() :: :ok
  def resume, do: :atomics.put(cell(), @draining, 0)

  defp wait(deadline) do
    cond do
      streams() == 0 ->
        Logger.info("drain complete")
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("drain timeout with #{streams()} streams still open")
        :timeout

      true ->
        Process.sleep(200)
        wait(deadline)
    end
  end

  @doc "Configured drain budget in milliseconds."
  @spec drain_timeout_ms() :: non_neg_integer()
  def drain_timeout_ms, do: Application.get_env(:conveyor, :shutdown_drain_seconds, 30) * 1000

  # --- what a refusal looks like on the wire ------------------------------------------------

  @doc "The one mapping from a refusal to the gRPC status Bazel sees."
  @spec grpc_error(Policy.reason(), Limits.limits() | nil) :: GRPC.RPCError.t()
  def grpc_error(reason, limits \\ nil) do
    {status, _http, message} = wire(reason, limits || Limits.defaults())
    GRPC.RPCError.exception(status: status, message: message)
  end

  @doc "The same for HTTP: `{status, message}`."
  @spec http_error(Policy.reason(), Limits.limits() | nil) :: {pos_integer(), String.t()}
  def http_error(reason, limits \\ nil) do
    {_status, http, message} = wire(reason, limits || Limits.defaults())
    {http, message}
  end

  # UNAVAILABLE is the status Bazel retries (and a balancer then tries another node).
  defp wire(:draining, _), do: {:unavailable, 503, "this node is draining; retry another"}

  defp wire(:overloaded, _),
    do: {:unavailable, 503, "this node is overloaded (commits are behind); retry"}

  defp wire(:key_share, _),
    do:
      {:unavailable, 503,
       "this node is under pressure and this API key holds more than its share of streams; retry"}

  defp wire(:key_streams, limits),
    do:
      {:resource_exhausted, 429,
       "too many concurrent streams for this API key (limit #{limits.max_streams})"}
end
