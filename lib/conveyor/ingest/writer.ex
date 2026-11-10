defmodule Conveyor.Ingest.Writer do
  @moduledoc """
  The commit pipeline of one shard: workers submit batches, each batch gets exactly one
  outcome. Batches of many invocations are committed together (group commit), and the
  acknowledgement of an event is the commit of its batch.

  ## Interface

  `submit/2` hands a batch to a shard (`WriterPool.for_invocation/1` names it) and returns
  the pid of the shard's process. The submitting process then receives exactly one of:

  | Outcome | Message | Meaning |
  |---|---|---|
  | committed | `{:batch_committed, ref}` | the batch is in the database (and its bytes in the raw log) |
  | fenced | `{:batch_failed, ref, {:fenced, seq}}` | the invocation row was not at `seq`: another session owns the build |
  | expired | `{:batch_failed, ref, :expired}` | the batch passed its deadline before a commit could start (or between two attempts) |
  | failed | `{:batch_failed, ref, reason}` | the database or the object store refused it after the policy's attempts |
  | writer down | `:DOWN` of the returned pid, or `{:error, :writer_down}` from `submit/2` | the shard's process went away. `{:error, :writer_down}`: the batch was never taken. `:DOWN` with a batch outstanding: **unknown**, it may have committed |

  A batch that is not reported committed is never acknowledged, and was not written, with
  one exception no writer can remove: a commit whose own acknowledgement is lost on the
  way back (the connection dies during `COMMIT`) looks like a failure although the row
  holds the batch. A submitter must therefore treat every outcome but committed as "may
  have committed" and re-read the row (`Conveyor.Ingest.Session` stops and the resend
  goes through the row). `docs/spec/Writer.tla` checks exactly this (`OneOutcome`,
  `Reported`, `Settled`).

  What a caller may rely on:

    * **One outcome, one process.** Every stage runs in the shard's process, so its death
      is the only way an outcome is not sent, and a monitor on the returned pid covers the
      whole pipeline.
    * **Order.** Batches of one invocation are committed in the order they were submitted;
      a batch never commits after a later one of its invocation, and when one does not
      commit, the later ones of its invocation in the same group do not either.
    * **A deadline.** `deadline_ms` after `submit/2` a batch no longer starts a commit, and
      a commit that has started runs with what is left as its timeout. Bazel waits 30 s
      for an acknowledgement and then resends on a new stream; an outcome later than that
      would only fence the stream that took over.
    * **Bounded work.** A group is planned and stored once and starts a bounded number of
      transactions whatever goes wrong (`Writer.Policy`).

  `pressure/1` reads what a shard has been handed and not answered.

  ## Inside

  One process per shard runs the stages in order; each is a module that can be read and
  tested alone:

    1. **When to commit**: `Writer.Flush` (pure) decides from what waits: a full group, enough
       bytes, the end of a stream, or the hold.
    2. **Units and deadlines**: the batches of a group are merged per invocation
       (`Batch.units/1`); units past their deadline leave as `:expired`.
    3. **Plan**: `Writer.Plan` compresses each unit's segments once and merges the rows per
       table.
    4. **Store**: `Writer.Store` puts the group's raw bytes into one object, once (blob mode).
    5. **Transaction**: `Writer.Transaction` writes the units of an attempt, fence first.
    6. **What next**: `Writer.Policy` (pure) turns the outcome of an attempt into the next
       one (retry, without the fenced units, halves) or the verdicts.

  Telemetry: `[:conveyor, :ingest, :writer, :flush]` per group (`duration`, `batches`,
  `events`, `wait`: how long its oldest batch waited for the outcome, ms),
  `[..., :group_failed]` per failed attempt (`kind`: `:fenced | :unavailable | :contention |
  :data`), `[..., :expired]` (`count` of units), `[:conveyor, :ingest, :fenced]` per fenced
  unit.
  """
  use GenServer

  require Logger

  alias Conveyor.Ingest.{Batch, TagCounter}
  alias Conveyor.Ingest.Writer.{Config, Flush, Plan, Policy, Store, Transaction}

  @registry Conveyor.Ingest.Registry

  # The shard's pressure gauge: batches and bytes handed over and not yet answered, and
  # when the oldest of them was handed over. Submitters add, the shard subtracts.
  @batches 1
  @bytes 2
  @oldest 3
  # No batch waits (a monotonic time can be any other integer).
  @none -9_223_372_036_854_775_808

  @type shard :: term()

  @doc """
  Starts a shard. Options: `:shard` (its name), `:config` (a `Writer.Config`; the node's by
  default).
  """
  # A gauge belongs to one incarnation of the shard and is registered with its name, so a
  # submitter always adds to the gauge of the process it hands the batch to: a restarted
  # shard starts from zero, and what was cast to the dead one is not counted against it.
  def start_link(opts) do
    shard = Keyword.fetch!(opts, :shard)
    gauge = :atomics.new(3, signed: true)
    :atomics.put(gauge, @oldest, @none)

    GenServer.start_link(__MODULE__, Keyword.put(opts, :gauge, gauge),
      name: {:via, Registry, {@registry, {:writer, shard}, gauge}}
    )
  end

  @doc "The process of a shard, or nil."
  @spec whereis(shard()) :: pid() | nil
  def whereis(shard) do
    case Registry.lookup(@registry, {:writer, shard}) do
      [{pid, _gauge}] -> pid
      [] -> nil
    end
  end

  @doc """
  Hands a batch to a shard. `{:ok, pid}`: the shard took it and the caller will receive
  its outcome (see the module documentation), unless `pid` goes away first.
  `{:error, :writer_down}`: no such shard is running and the batch was not taken.
  """
  @spec submit(shard(), Batch.t()) :: {:ok, pid()} | {:error, :writer_down}
  def submit(shard, %Batch{} = batch) do
    case Registry.lookup(@registry, {:writer, shard}) do
      [{pid, gauge}] ->
        at = now_ms()
        :atomics.add(gauge, @batches, 1)
        :atomics.add(gauge, @bytes, batch.event_bytes + batch.log_bytes)
        :atomics.compare_exchange(gauge, @oldest, @none, at)
        # The waiters are the submitter's business: the shard answers with the ref.
        GenServer.cast(pid, {:submit, %{batch | waiters: []}, self(), at})
        {:ok, pid}

      [] ->
        {:error, :writer_down}
    end
  end

  @doc """
  What a shard has been handed and has not answered yet: `batches`, their `bytes` (event
  and log bytes as received) and `oldest_ms`, the age of the oldest one. It covers the
  shard's mailbox as well as the group it is collecting or committing, so a shard stuck in
  a slow commit shows its age growing. Read from counters: no message to the shard.
  """
  @spec pressure(shard()) :: %{
          batches: non_neg_integer(),
          bytes: non_neg_integer(),
          oldest_ms: non_neg_integer()
        }
  def pressure(shard) do
    case Registry.lookup(@registry, {:writer, shard}) do
      [{_pid, gauge}] ->
        oldest = :atomics.get(gauge, @oldest)

        %{
          batches: max(:atomics.get(gauge, @batches), 0),
          bytes: max(:atomics.get(gauge, @bytes), 0),
          oldest_ms: if(oldest == @none, do: 0, else: max(now_ms() - oldest, 0))
        }

      [] ->
        %{batches: 0, bytes: 0, oldest_ms: 0}
    end
  end

  # --- the process --------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       shard: Keyword.fetch!(opts, :shard),
       config: Keyword.get_lazy(opts, :config, &Config.from_env/0),
       gauge: Keyword.fetch!(opts, :gauge),
       # Compression contexts live as long as the shard: creating one per segment cost
       # more than a third of a small segment's compression.
       compressors: Plan.compressors(),
       # {batch, submitter, submitted at}, newest first
       pending: [],
       # when the oldest pending batch was submitted
       oldest: nil,
       count: 0,
       bytes: 0,
       timer: nil
     }}
  end

  @impl true
  def handle_cast({:submit, batch, from, at}, state) do
    # The submitter's own mark loses to an older one still standing; with nothing pending
    # this batch is the oldest the shard holds.
    if state.pending == [], do: :atomics.put(state.gauge, @oldest, at)

    state = %{
      state
      | pending: [{batch, from, at} | state.pending],
        oldest: state.oldest || at,
        count: state.count + 1,
        bytes: state.bytes + batch.event_bytes + batch.log_bytes
    }

    waiting = %{
      count: state.count,
      bytes: state.bytes,
      oldest_ms: now_ms() - state.oldest,
      finalize?: batch.finalize
    }

    case Flush.decide(waiting, state.config) do
      :flush -> {:noreply, flush(state)}
      {:wait, _ms} when state.timer != nil -> {:noreply, state}
      {:wait, ms} -> {:noreply, %{state | timer: :erlang.start_timer(ms, self(), :flush)}}
    end
  end

  @impl true
  def handle_info({:timeout, timer, :flush}, %{timer: timer} = state),
    do: {:noreply, flush(%{state | timer: nil})}

  # A hold that elapsed while its group was already being committed.
  def handle_info({:timeout, _timer, :flush}, state), do: {:noreply, state}

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    if state.timer, do: :erlang.cancel_timer(state.timer)
    entries = Enum.reverse(state.pending)
    started = System.monotonic_time()

    verdicts = commit(entries, state)

    Enum.each(entries, fn {batch, from, _at} ->
      case Map.fetch!(verdicts, batch.ref) do
        :committed -> send(from, {:batch_committed, batch.ref})
        :fenced -> send(from, {:batch_failed, batch.ref, {:fenced, batch.first_seq - 1}})
        :expired -> send(from, {:batch_failed, batch.ref, :expired})
        {:failed, reason} -> send(from, {:batch_failed, batch.ref, reason})
      end
    end)

    # Everything pending is answered. What arrived meanwhile is in the mailbox; the first
    # of it marks the gauge again when it is taken out.
    :atomics.sub(state.gauge, @batches, state.count)
    :atomics.sub(state.gauge, @bytes, state.bytes)
    :atomics.put(state.gauge, @oldest, @none)

    :telemetry.execute(
      [:conveyor, :ingest, :writer, :flush],
      %{
        duration: System.monotonic_time() - started,
        batches: state.count,
        events: Enum.sum(Enum.map(entries, fn {b, _, _} -> Batch.event_count(b) end)),
        wait: now_ms() - state.oldest
      },
      %{shard: state.shard}
    )

    %{state | pending: [], oldest: nil, count: 0, bytes: 0, timer: nil}
  end

  # --- one group ----------------------------------------------------------------------------

  # One group, one verdict per batch (by ref). The group is planned once: its batches are
  # merged into units, each unit's segments are compressed once, and in blob mode their
  # bytes are stored as one object, once. Every attempt after that (a retry, the group
  # without its fenced units, a half of it) is a transaction over a subset of the units
  # that points at the same object and byte ranges. What follows a failed attempt is the
  # policy's decision.
  defp commit(entries, %{config: config} = state) do
    units = entries |> Enum.map(&elem(&1, 0)) |> Batch.units()
    submitted = Map.new(entries, fn {batch, _from, at} -> {batch.ref, at} end)

    # A unit is due when its oldest batch is.
    deadlines =
      Map.new(units, fn {key, _unit, refs} ->
        {key, (refs |> Enum.map(&Map.fetch!(submitted, &1)) |> Enum.min()) + config.deadline_ms}
      end)

    policy =
      units
      |> Enum.map(&elem(&1, 0))
      |> Policy.new(retry_delays: config.retry_delays)
      |> expire(deadlines, now_ms())

    # Only what is still wanted is planned (compressed) and stored.
    keys = Policy.open(policy)
    by_key = Map.new(units, fn {key, unit, _refs} -> {key, unit} end)
    segments = Map.new(keys, &{&1, Plan.segments(Map.fetch!(by_key, &1), state.compressors)})

    group = %{
      shard: state.shard,
      units: by_key,
      deadlines: deadlines,
      store: Store.new(keys, segments, state.shard, config.blob?)
    }

    verdicts = run(policy, group)
    report(state.shard, verdicts)
    for {key, _unit, refs} <- units, ref <- refs, into: %{}, do: {ref, Map.fetch!(verdicts, key)}
  end

  defp run(policy, group) do
    now = now_ms()

    case policy |> expire(group.deadlines, now) |> Policy.next() do
      {:done, verdicts} ->
        verdicts

      {:attempt, keys, policy} ->
        # What is left until the first deadline in the attempt.
        budget = (keys |> Enum.map(&Map.fetch!(group.deadlines, &1)) |> Enum.min()) - now
        {outcome, group} = attempt(keys, group, budget)

        if outcome != :committed do
          # Every failed attempt is redone in some form; count it, a failure in every flush
          # would raise the write cost silently otherwise.
          :telemetry.execute([:conveyor, :ingest, :writer, :group_failed], %{count: 1}, %{
            shard: group.shard,
            batches: length(keys),
            kind: kind(outcome),
            reason: reason(outcome)
          })
        end

        {policy, delay} = Policy.record(policy, outcome)
        if delay > 0, do: Process.sleep(delay)
        run(policy, group)
    end
  end

  # Units past their deadline leave before the next attempt (and take the later units of
  # their invocations along): they are never written, so `:expired` means "not committed",
  # and the attempt that follows carries only work somebody still waits for.
  defp expire(policy, deadlines, now) do
    case Enum.filter(Policy.open(policy), &(Map.fetch!(deadlines, &1) <= now)) do
      [] -> policy
      late -> Policy.evict(policy, late, :expired)
    end
  end

  defp attempt(keys, group, budget) do
    case Store.put(group.store) do
      {:ok, store} ->
        units = Enum.map(keys, &{&1, Map.fetch!(group.units, &1)})
        plan = units |> Enum.map(&elem(&1, 1)) |> Plan.rows(Store.segments(store, keys))
        outcome = Transaction.run(units, plan, budget)

        # Tag counts are rows shared by every invocation of a project. Updating them inside
        # the group transaction made every shard queue on the same row locks for the whole
        # commit (measured: >90 % of active backends waiting on tag_keys), so they go to
        # the node's TagCounter after the commit.
        if outcome == :committed, do: TagCounter.add(plan.tag_counts)
        {outcome, %{group | store: store}}

      # The store refusing the object is no fault of a batch: the same object is put again
      # by the next attempt.
      {:error, reason} ->
        {{:error, :unavailable, reason}, group}
    end
  end

  defp kind({:fenced, _keys}), do: :fenced
  defp kind({:error, class, _reason}), do: class

  defp reason({:fenced, keys}), do: "#{length(keys)} fenced"
  defp reason({:error, _class, reason}), do: reason

  defp report(shard, verdicts) do
    for {{id, _n}, :fenced} <- verdicts do
      :telemetry.execute([:conveyor, :ingest, :fenced], %{count: 1}, %{invocation_id: id})
    end

    case Enum.count(verdicts, fn {_key, verdict} -> verdict == :expired end) do
      0 ->
        :ok

      expired ->
        :telemetry.execute([:conveyor, :ingest, :writer, :expired], %{count: expired}, %{
          shard: shard
        })

        Logger.warning(
          "writer shard #{inspect(shard)}: #{expired} of #{map_size(verdicts)} units expired before their commit could start"
        )
    end

    case for {_key, {:failed, reason}} <- verdicts, do: reason do
      [] ->
        :ok

      [reason | _] = failed ->
        Logger.error(
          "writer shard #{inspect(shard)}: #{length(failed)} of #{map_size(verdicts)} units failed: #{inspect(reason)}"
        )
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
