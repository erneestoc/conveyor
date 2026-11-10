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
  | 2 shedding | 0.25 | 0.10 | a share of the new builds that grows from none at 0.25 to all at 0.50 (`shed_all`); a resumed stream (a build that already has events) is still taken. The share falls back slowly, `readmit_per_s` points per second, whatever the level |
  | 3 critical | 0.75 | 0.50 | every new build, and a share of the builds in progress that grows from none at 0.75 to all at 1.0: their next event, and their stream when they reconnect |

  A level is left only below its own, lower, threshold, so the node does not flap around
  one value. Inside a level the refusals are graded, not all or nothing: a build has a
  fixed bucket in `0..99` and is refused while the share that applies to it is above it.
  Refusing everything at one threshold and nothing below it makes the load swing between
  the two with the period of a build; a share that follows the pressure settles where the
  admitted load is what the node can commit. A build's bucket is a hash of its invocation
  id, so every node gives the same build the same answer at the same pressure, a retry
  does not get lucky, and a build that was shed stays shed when it reconnects: the ones
  that were kept can finish. Draining and the per-key stream limit are judged at the stream door whatever
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
            # Floats: they fall by fractions of a point per sample.
            events_pct: 0.0,
            builds_pct: 0.0,
            at: nil,
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

    # What was refused comes back slowly: a refused share rises with the pressure at once
    # and falls by `readmit_per_s` points per second, whatever the level. The pressure is
    # an age, so it shows what was admitted only a commit later; a node that has just shed
    # everything reads 0 and would otherwise take every waiting client back in the same
    # second. (Taking back faster while the node reads idle was tried: a node that has
    # shed everything reads idle too. PLAN §26.4.)
    seconds = if s.at, do: max(now_ms - s.at, 0) / 1000, else: 0.0
    back = if c.enabled, do: c.readmit_per_s * seconds, else: 100.0

    %{
      s
      | window: window,
        pressure: peak,
        level: level,
        at: now_ms,
        events_pct: max(events_pct(level, peak, c) * 1.0, s.events_pct - back),
        builds_pct: max(builds_pct(level, peak, c) * 1.0, s.builds_pct - back)
    }
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
  defp events_pct(@critical, peak, c), do: share(peak, elem(c.enter, @critical - 1), 1.0)
  defp events_pct(_level, _peak, _c), do: 0

  # The share of new builds refused: none where the shedding level is entered, all from
  # `shed_all` on and at the critical level.
  defp builds_pct(@critical, _peak, _c), do: 100
  defp builds_pct(@shedding, peak, c), do: share(peak, elem(c.enter, @shedding - 1), c.shed_all)
  defp builds_pct(_level, _peak, _c), do: 0

  defp share(peak, from, to),
    do: round(100 * (peak - from) / max(to - from, 0.01)) |> max(0) |> min(100)

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

    * `:stream` — a stream is opened; the build is not known yet. `request`:
      `%{draining?, key_streams, max_streams}` (`max_streams` may be `:infinity`).
    * `:build` — the first event of a stream, or the notification that announces a build,
      says which build it is. `request`: `%{resumed?, over_share?, bucket}`: the build's
      fixed bucket in `0..99`.
    * `:event` — the next event of an open stream. `request`: `%{bucket, token?}`: the
      build's bucket and whether its key had a token left.
  """
  @spec decide(door(), map(), map()) :: decision()
  def decide(:stream, _state, %{draining?: true}), do: {:refuse, :draining}

  def decide(:stream, _state, %{key_streams: n, max_streams: max})
      when is_integer(max) and n >= max,
      do: {:refuse, :key_streams}

  def decide(:stream, _state, _request), do: :accept

  # A build in progress is refused only by the share that also refuses its events; a new
  # one by the (larger, earlier) share of new builds, and before that when its key is
  # above its share.
  def decide(:build, %{events_pct: pct}, %{bucket: bucket}) when pct > bucket,
    do: {:refuse, :overloaded}

  def decide(:build, _state, %{resumed?: true}), do: :accept

  def decide(:build, %{level: level}, %{over_share?: true}) when level >= 1,
    do: {:refuse, :key_share}

  def decide(:build, %{builds_pct: pct}, %{bucket: bucket}) when pct > bucket,
    do: {:refuse, :overloaded}

  def decide(:build, _state, _request), do: :accept

  def decide(:event, %{events_pct: pct}, %{bucket: bucket}) when pct > bucket,
    do: {:refuse, :overloaded}

  def decide(:event, _state, %{token?: false}), do: {:slow, 10}
  def decide(:event, _state, _request), do: :accept
end
