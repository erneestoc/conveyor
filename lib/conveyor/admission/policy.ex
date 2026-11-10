defmodule Conveyor.Admission.Policy do
  @moduledoc """
  The decisions of admission, pure: no process, no clock, no database.

  Two functions carry everything. `step/4` folds one sample of the node's signals into the
  policy's state (the pressure, the level with its hysteresis, the share of streams whose
  events are refused, readiness). `decide/3` answers a door: accept, slow down or refuse.
  `Conveyor.Admission.Sampler` calls `step/4` at a fixed interval and publishes the result;
  the doors of `Conveyor.Admission` read it.

  ## Pressure

  One number, in deadlines: `0.0` is an idle node, `1.0` is the point where batches expire.

      pressure = max( (oldest_ms - hold_ms) / deadline_ms,      commit latency
                      queue_ms / (2 * queue_target_ms),         waiting for a connection
                      bytes / max_backlog_bytes )               memory held for the writer

  `oldest_ms` is the age of the oldest batch any writer shard has not answered
  (`WriterPool.pressure/0`). The policy uses the maximum of the last `window` samples: the
  gauge reads 0 between a flush and the next batch, and an age is already an integral, so
  one sample above a threshold is not a spike.

  ## Levels

  | level | enters at | leaves at | what is refused |
  |---|---|---|---|
  | 0 normal | | | nothing |
  | 1 elevated | 0.15 | 0.05 | new builds of a key that holds more than its share of the node's streams |
  | 2 shedding | 0.25 | 0.10 | every new build; a resumed stream (a build that already has events) is still taken |
  | 3 critical | 0.75 | 0.50 | every new stream, and the events of a share of the open streams that grows from none at 0.75 to all at 1.0 |

  A level is left only below its own, lower, threshold, so the node does not flap around
  one value. Draining and the per-key stream limit are judged at the stream door whatever
  the level.

  ## Readiness

  A node that sheds stays in the balancer: the doors already answer UNAVAILABLE at once,
  and when the cause is shared (the database), every node sheds and none may leave. The
  node reports not ready for pressure only when it has been shedding for
  `unready_after_ms`, it knows peers, and more than half of them are not shedding: then it
  is the outlier and the others have room. It stays out at least `unready_min_ms` (a
  balancer needs two or three probes to notice either way). The database check follows the
  same rule: `probe_failures` failed probes in a row count as "gone" unless at least half
  of the peers have lost it too; a node without peers keeps the old behaviour (not ready
  without its database). A node that has never reached its database is not ready.
  """

  alias Conveyor.Admission.Config

  defstruct level: 0,
            pressure: 0.0,
            window: [],
            events_pct: 0,
            ready: true,
            pressured_since: nil,
            unready_at: nil,
            db_seen: false,
            db_failures: 0

  @type level :: 0..3
  @type t :: %__MODULE__{}

  @type signals :: %{
          optional(:oldest_ms) => non_neg_integer(),
          optional(:bytes) => non_neg_integer(),
          optional(:queue_ms) => number(),
          # the last database probe: nil when none ran since the last sample
          optional(:db) => :ok | :error | nil,
          # what the other nodes last said about themselves
          optional(:peers) => [%{level: level(), db_ok: boolean()}]
        }

  @type door :: :stream | :build | :event
  @type reason :: :draining | :overloaded | :key_streams | :key_share
  @type decision :: :accept | {:slow, pos_integer()} | {:refuse, reason()}

  @names {:normal, :elevated, :shedding, :critical}
  @shedding 2
  @critical 3

  @doc "The name of a level."
  @spec name(level()) :: :normal | :elevated | :shedding | :critical
  def name(level), do: elem(@names, level)

  @doc "A node that has seen nothing yet. Without a database probe the database counts as seen."
  @spec new(Config.t()) :: t()
  def new(%Config{} = config), do: %__MODULE__{db_seen: config.probe_ms == 0}

  @doc "The pressure of one sample, in deadlines."
  @spec pressure(signals(), Config.t()) :: float()
  def pressure(signals, %Config{} = c) do
    latency = max(Map.get(signals, :oldest_ms, 0) - c.hold_ms, 0) / max(c.deadline_ms, 1)
    queue = Map.get(signals, :queue_ms, 0) / max(2 * c.queue_target_ms, 1)
    memory = Map.get(signals, :bytes, 0) / max(c.max_backlog_bytes, 1)
    Enum.max([latency, queue, memory]) * 1.0
  end

  @doc "Folds one sample taken at `now_ms` (monotonic) into the state."
  @spec step(t(), signals(), integer(), Config.t()) :: t()
  def step(%__MODULE__{} = s, signals, now_ms, %Config{} = c) do
    window = Enum.take([pressure(signals, c) | s.window], c.window)
    peak = Enum.max(window)
    level = if c.enabled, do: s.level |> up(peak, c) |> down(peak, c), else: 0

    %{s | window: window, pressure: peak, level: level, events_pct: events_pct(level, peak, c)}
    |> database(Map.get(signals, :db))
    |> readiness(Map.get(signals, :peers, []), now_ms, c)
  end

  defp up(level, peak, c) when level < @critical do
    if peak >= elem(c.enter, level), do: up(level + 1, peak, c), else: level
  end

  defp up(level, _peak, _c), do: level

  defp down(level, peak, c) when level > 0 do
    if peak <= elem(c.exit, level - 1), do: down(level - 1, peak, c), else: level
  end

  defp down(level, _peak, _c), do: level

  # The share of open streams whose next event is refused: none where the critical level
  # is entered, all at the deadline, where their batches would expire anyway.
  defp events_pct(@critical, peak, c) do
    from = elem(c.enter, @critical - 1)
    round(100 * (peak - from) / max(1.0 - from, 0.01)) |> max(0) |> min(100)
  end

  defp events_pct(_level, _peak, _c), do: 0

  defp database(s, :ok), do: %{s | db_seen: true, db_failures: 0}
  defp database(s, :error), do: %{s | db_failures: s.db_failures + 1}
  defp database(s, nil), do: s

  defp readiness(s, peers, now, c) do
    pressured_since =
      cond do
        s.level < @shedding -> nil
        s.pressured_since == nil -> now
        true -> s.pressured_since
      end

    outlier? = s.level >= @shedding and most?(peers, &(&1.level < @shedding))

    unready_at =
      cond do
        # Out: at least the minimum, then for as long as it is still the outlier.
        s.unready_at != nil and now - s.unready_at < c.unready_min_ms -> s.unready_at
        s.unready_at != nil and outlier? -> s.unready_at
        s.unready_at != nil -> nil
        outlier? and now - pressured_since >= c.unready_after_ms -> now
        true -> nil
      end

    db_gone? =
      s.db_failures >= c.probe_failures and (peers == [] or most?(peers, & &1.db_ok))

    %{
      s
      | pressured_since: pressured_since,
        unready_at: unready_at,
        ready: s.db_seen and not db_gone? and unready_at == nil
    }
  end

  # More than half of the peers, and there is at least one.
  defp most?(peers, fun), do: 2 * Enum.count(peers, fun) > length(peers)

  @doc """
  The answer at a door.

    * `:stream` — a stream is opened. `request`: `%{draining?, key_streams, max_streams}`
      (`max_streams` may be `:infinity`).
    * `:build` — the first event of a stream, or the notification that announces a build,
      says which build it is. `request`: `%{resumed?, over_share?}`.
    * `:event` — the next event of an open stream. `request`: `%{bucket, token?}`: the
      stream's fixed bucket in `0..99` and whether its key had a token left.
  """
  @spec decide(door(), %{level: level(), events_pct: 0..100}, map()) :: decision()
  def decide(:stream, _state, %{draining?: true}), do: {:refuse, :draining}

  def decide(:stream, _state, %{key_streams: n, max_streams: max})
      when is_integer(max) and n >= max,
      do: {:refuse, :key_streams}

  def decide(:stream, %{level: @critical}, _request), do: {:refuse, :overloaded}
  def decide(:stream, _state, _request), do: :accept

  def decide(:build, %{level: @critical}, _request), do: {:refuse, :overloaded}
  def decide(:build, _state, %{resumed?: true}), do: :accept
  def decide(:build, %{level: @shedding}, _request), do: {:refuse, :overloaded}
  def decide(:build, %{level: 1}, %{over_share?: true}), do: {:refuse, :key_share}
  def decide(:build, _state, _request), do: :accept

  def decide(:event, %{events_pct: pct}, %{bucket: bucket}) when pct > bucket,
    do: {:refuse, :overloaded}

  def decide(:event, _state, %{token?: false}), do: {:slow, 10}
  def decide(:event, _state, _request), do: :accept
end
