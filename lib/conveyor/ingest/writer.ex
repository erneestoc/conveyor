defmodule Conveyor.Ingest.Writer do
  @moduledoc """
  Group-commit writer. Workers submit batches; every `writer_flush_ms` (or sooner when the
  queue is large) the writer commits all pending batches from many invocations in one
  transaction and notifies each submitter. A group is planned and, in blob mode, stored as
  one object once; what happens after a failed transaction (retry, the group without its
  fenced units, halves, or failing the group) is `Conveyor.Ingest.Writer.Policy`.

  Inside the transaction the fence goes first: one fenced invocation update per set of dirty
  columns (`UPDATE … FROM unnest(...)`, PLAN §24 item 1, rows in id order), so a group with
  a stale batch aborts before it writes a child row. Then the group is written table by
  table: one statement per table and column set for segments, targets, tests, actions and
  metrics.
  Batches of one invocation that follow each other are merged first, so an invocation
  costs one segment, one log row and one update row per flush however many batches it
  submitted. Round trips grow with the number of tables, not batches.
  """
  use GenServer

  require Logger

  alias Conveyor.Ingest.{Batch, TagCounter}
  alias Conveyor.Ingest.Writer.Policy

  alias Conveyor.Invocations.{
    Action,
    EventSegment,
    Invocation,
    LogSegment,
    Metrics,
    Target,
    TestResult
  }

  alias Conveyor.Repo
  alias Conveyor.RawLog

  defmodule Fenced do
    @moduledoc """
    Raised inside the group transaction when invocation rows no longer match the sequence
    their units expect. `units` lists the key of every unit the statements fenced, so the
    group can be attempted again without them.
    """
    defexception units: []

    def message(e), do: "#{length(e.units)} units fenced: last_event_seq moved"
  end

  @target_key [:invocation_id, :label, :aspect]
  @test_key [:invocation_id, :label, :configuration_id, :run, :shard, :attempt]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: name(Keyword.fetch!(opts, :shard)))

  def name(shard), do: {:via, Registry, {Conveyor.Ingest.Registry, {:writer, shard}}}

  @doc """
  Queues a batch. The delivery contract with the submitter:

    * the writer sends the caller exactly one of `{:batch_committed, ref}` or
      `{:batch_failed, ref, reason}` for every batch it took, and it does so before it
      handles anything else. `reason` is `{:fenced, seq}` (the row moved: another worker
      owns the build), `:expired` (the batch waited past its deadline and was never
      attempted, or was dropped between attempts once it had) or the error;
    * a batch has a deadline, `writer_deadline_ms` after this call. A commit that has not
      started by then never starts, and one that has started runs with the rest of the
      budget as its timeout: an outcome arrives while the client still waits for the
      acknowledgement, not after it has given up and resent elsewhere;
    * the only way an outcome is never sent is the writer process going away. `submit/2`
      returns the writer's pid so the caller can monitor it; a `:DOWN` with batches
      outstanding means their outcome is unknown (a batch may have committed), and
      `{:error, :writer_down}` means the batch was never queued.
  """
  @spec submit(GenServer.name(), Batch.t()) :: {:ok, pid()} | {:error, :writer_down}
  def submit(writer, %Batch{} = batch) do
    case GenServer.whereis(writer) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:submit, batch, self(), now_ms()})
        {:ok, pid}

      nil ->
        {:error, :writer_down}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       shard: opts[:shard],
       pending: [],
       count: 0,
       timer: nil,
       flush_ms:
         if(RawLog.blob_mode?(), do: RawLog.flush_ms(), else: config(:writer_flush_ms, 20)),
       max_pending: config(:writer_max_pending, 256),
       # How long after its submission a batch may still start a commit. Bazel waits 30 s
       # for an acknowledgement before it resends on a new stream; an outcome later than
       # that only fences the stream that took over.
       deadline_ms: Keyword.get(opts, :deadline_ms, config(:writer_deadline_ms, 20_000)),
       # Waits between attempts while the database or the store is unavailable (Policy).
       retry_delays: config(:writer_retry_delays, [50, 200, 800]),
       # Blob mode only: the hold is long, so a shard under load flushes by size instead.
       bytes: 0,
       max_bytes: if(RawLog.blob_mode?(), do: RawLog.flush_bytes(), else: nil)
     }}
  end

  @impl true
  def handle_cast({:submit, batch, from, at}, state) do
    state = %{
      state
      | pending: [{batch, from, at} | state.pending],
        count: state.count + 1,
        bytes: state.bytes + batch.event_bytes + batch.log_bytes
    }

    cond do
      state.count >= state.max_pending ->
        {:noreply, flush(state)}

      state.max_bytes != nil and state.bytes >= state.max_bytes ->
        {:noreply, flush(state)}

      # The batch that ends a stream carries the build's final status and its last ack:
      # Bazel is waiting on it, so it never waits for the hold (blob mode's is a second).
      batch.finalize ->
        {:noreply, flush(state)}

      state.timer == nil ->
        {:noreply, %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    pending = Enum.reverse(state.pending)
    started = System.monotonic_time()

    results = commit(pending, state)

    Enum.each(results, fn
      {batch, from, :ok} -> send(from, {:batch_committed, batch.ref})
      {batch, from, {:error, reason}} -> send(from, {:batch_failed, batch.ref, reason})
    end)

    :telemetry.execute(
      [:conveyor, :ingest, :writer, :flush],
      %{
        duration: System.monotonic_time() - started,
        batches: length(pending),
        events: Enum.sum(Enum.map(pending, fn {b, _, _} -> Batch.event_count(b) end))
      },
      %{shard: state.shard}
    )

    %{state | pending: [], count: 0, bytes: 0, timer: nil}
  end

  # One group, one outcome per batch. The group is planned once: its batches are merged
  # into units, each unit's segments are compressed once, and in blob mode their bytes are
  # stored as one object, once. Every attempt after that (a retry, the group without its
  # fenced units, a half of it) is a transaction over a subset of the units that points at
  # the same object and byte ranges; an evicted unit's bytes stay in the object,
  # unreferenced. What follows a failed attempt is `Writer.Policy`'s decision.
  defp commit(entries, state) do
    units = entries |> Enum.map(&elem(&1, 0)) |> Batch.units()
    submitted = Map.new(entries, fn {batch, _from, at} -> {batch.ref, at} end)

    # A unit is due when its oldest batch is.
    deadlines =
      Map.new(units, fn {key, _unit, refs} ->
        {key, (refs |> Enum.map(&Map.fetch!(submitted, &1)) |> Enum.min()) + state.deadline_ms}
      end)

    policy =
      units
      |> Enum.map(&elem(&1, 0))
      |> Policy.new(retry_delays: state.retry_delays)
      |> expire(deadlines, now_ms())

    # Only what is still wanted is planned (compressed) and stored.
    keys = Policy.open(policy)
    by_key = Map.new(units, fn {key, unit, _refs} -> {key, unit} end)

    group = %{
      shard: state.shard,
      keys: keys,
      units: by_key,
      segments: {:planned, Map.new(keys, &{&1, segments(Map.fetch!(by_key, &1))})},
      deadlines: deadlines
    }

    verdicts = run(policy, group)
    by_ref = for {key, _unit, refs} <- units, ref <- refs, into: %{}, do: {ref, verdicts[key]}

    report_failures(state.shard, verdicts)

    Enum.map(entries, fn {batch, from, _at} -> {batch, from, result(batch, by_ref[batch.ref])} end)
  end

  defp run(policy, group) do
    now = now_ms()

    case policy |> expire(group.deadlines, now) |> Policy.next() do
      {:done, verdicts} ->
        verdicts

      {:attempt, keys, policy} ->
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp kind({:fenced, _keys}), do: :fenced
  defp kind({:error, class, _reason}), do: class

  defp reason({:fenced, keys}), do: "#{length(keys)} fenced"
  defp reason({:error, _class, reason}), do: reason

  defp attempt(keys, group, budget) do
    case store(group) do
      {:ok, %{segments: {:stored, segments}} = group} ->
        units = Enum.map(keys, &{&1, Map.fetch!(group.units, &1)})
        plan = units |> Enum.map(&elem(&1, 1)) |> plan(Enum.map(keys, &Map.fetch!(segments, &1)))
        {transact(plan, units, budget), group}

      {:error, reason} ->
        {{:error, :unavailable, reason}, group}
    end
  end

  # `budget` is what is left until the first deadline in the attempt: the transaction and
  # each of its statements give up (client side: the connection is dropped, the server
  # rolls back) when it is spent.
  defp transact(plan, units, budget) do
    Repo.transaction(fn -> apply_plan!(plan, units, budget) end, timeout: budget)
    # Tag counts are rows shared by every invocation of a project. Updating them inside the
    # group transaction made every shard queue on the same row locks for the whole commit
    # (measured: >90 % of active backends waiting on tag_keys), so they go to the node's
    # TagCounter after the commit.
    TagCounter.add(plan.tag_counts)
    :committed
  rescue
    e in Fenced -> {:fenced, e.units}
    e -> {:error, error_class(e), Exception.message(e)}
  end

  # What the policy needs to know about a failed transaction: is the database refusing
  # work, is another transaction in the way, or is it this group's rows.
  defp error_class(%DBConnection.ConnectionError{}), do: :unavailable

  defp error_class(%Postgrex.Error{postgres: %{code: code}})
       when code in [:too_many_connections, :cannot_connect_now, :admin_shutdown],
       do: :unavailable

  defp error_class(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, :deadlock_detected],
       do: :contention

  defp error_class(_), do: :data

  defp result(_batch, :committed), do: :ok
  defp result(batch, :fenced), do: {:error, {:fenced, batch.first_seq - 1}}
  defp result(_batch, :expired), do: {:error, :expired}
  defp result(_batch, {:failed, reason}), do: {:error, reason}

  defp report_failures(shard, verdicts) do
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

  # Blob mode (PLAN §25 step 2): the group's payloads go into one raw-log object before
  # the first transaction, and the rows carry the byte range. The object is put once per
  # group: a put that failed is tried again under the same key by the next attempt.
  defp store(%{segments: {:stored, _}} = group), do: {:ok, group}

  defp store(%{segments: {:planned, segments}} = group) do
    if RawLog.blob_mode?() and Enum.any?(segments, fn {_key, rows} -> rows != {nil, nil} end) do
      keys = group.keys
      rows = Enum.map(keys, &Map.fetch!(segments, &1))

      {plan, key, body} =
        RawLog.objectify(
          %{
            event_rows: for({row, _} <- rows, row != nil, do: row),
            log_rows: for({_, row} <- rows, row != nil, do: row)
          },
          group.shard
        )

      store(%{group | segments: {:objectified, zip(keys, rows, plan), key, body}})
    else
      {:ok, %{group | segments: {:stored, segments}}}
    end
  end

  defp store(%{segments: {:objectified, segments, key, body}} = group) do
    case RawLog.put(key, body) do
      :ok ->
        :telemetry.execute(
          [:conveyor, :raw_log, :put],
          %{count: 1, bytes: IO.iodata_length(body)},
          %{shard: group.shard}
        )

        {:ok, %{group | segments: {:stored, segments}}}

      {:error, reason} ->
        :telemetry.execute([:conveyor, :raw_log, :put_failed], %{count: 1}, %{shard: group.shard})
        {:error, "raw log put #{key} failed: #{inspect(reason)}"}
    end
  end

  # `RawLog.objectify/2` keeps the order of the rows it is given: hand each unit its rows
  # back.
  defp zip(keys, rows, plan) do
    {segments, {[], []}} =
      keys
      |> Enum.zip(rows)
      |> Enum.map_reduce({plan.event_rows, plan.log_rows}, fn {key, {event, log}},
                                                              {events, logs} ->
        {event, events} = if event, do: {hd(events), tl(events)}, else: {nil, events}
        {log, logs} = if log, do: {hd(logs), tl(logs)}, else: {nil, logs}
        {{key, {event, log}}, {events, logs}}
      end)

    Map.new(segments)
  end

  # The segment rows of a unit, compressed: `{event row | nil, log row | nil}`.
  defp segments(%Batch{} = unit),
    do: {Batch.event_segment_row(unit), Batch.log_segment_row(unit)}

  @doc """
  The rows every table receives for a group of units, merged across them. Pure; `segments`
  are the units' segment rows when they were made before (they are compressed, and in blob
  mode stored, once per group).
  """
  @spec plan([Batch.t()], [{map() | nil, map() | nil}] | nil) :: map()
  def plan(units, segments \\ nil) do
    now = DateTime.utc_now()
    segments = segments || Enum.map(units, &segments/1)

    %{
      event_rows: for({row, _} <- segments, row != nil, do: row),
      log_rows: for({_, row} <- segments, row != nil, do: row),
      targets: merged_rows(units, :targets),
      tests: merged_rows(units, :tests),
      actions: flat_rows(units, :actions),
      metrics: metrics_rows(units, now),
      tag_counts: tag_counts(units)
    }
  end

  # Writes a planned group inside the current transaction. The fenced updates go first: a
  # group with a stale batch aborts before it has written a child row (or its WAL), and the
  # invocation rows, locked in id order, are the first locks every node's group takes for a
  # build, so two groups that hold the same build queue on its row instead of interleaving
  # their child upserts. Raises on failure.
  defp apply_plan!(plan, units, timeout) do
    update_invocations!(units, timeout)

    if plan.event_rows != [],
      do: Repo.insert_all(EventSegment, plan.event_rows, on_conflict: :nothing, timeout: timeout)

    if plan.log_rows != [],
      do: Repo.insert_all(LogSegment, plan.log_rows, on_conflict: :nothing, timeout: timeout)

    upsert_grouped(Target, plan.targets, @target_key, [], timeout)
    upsert_grouped(TestResult, plan.tests, @test_key, [], timeout)

    if plan.actions != [],
      do:
        Repo.insert_all(Action, plan.actions,
          on_conflict: :nothing,
          conflict_target: [:invocation_id, :seq],
          timeout: timeout
        )

    upsert_grouped(Metrics, plan.metrics, [:invocation_id], [:inserted_at], timeout)
    :ok
  end

  # Keyed rows (targets, tests) merged per invocation and key, later batches over earlier
  # ones: one upsert must not touch the same row twice, and the result must equal applying
  # the batches in order.
  defp merged_rows(batches, field) do
    batches
    |> Enum.reduce(%{}, fn b, acc ->
      Enum.reduce(Map.fetch!(b, field), acc, fn {key, attrs}, acc ->
        Map.update(
          acc,
          {b.invocation_id, key},
          Map.put(attrs, :invocation_id, b.invocation_id),
          &Map.merge(&1, attrs)
        )
      end)
    end)
    |> Map.values()
  end

  defp flat_rows(batches, field) do
    Enum.flat_map(batches, fn b ->
      b
      |> Map.fetch!(field)
      |> Enum.reverse()
      |> Enum.map(&Map.put(&1, :invocation_id, b.invocation_id))
    end)
  end

  defp metrics_rows(batches, now) do
    batches
    |> Enum.reduce(%{}, fn
      %{metrics: nil}, acc -> acc
      b, acc -> Map.update(acc, b.invocation_id, b.metrics, &Map.merge(&1, b.metrics))
    end)
    |> Enum.map(fn {id, metrics} ->
      Map.merge(metrics, %{invocation_id: id, inserted_at: now, updated_at: now})
    end)
  end

  # Counts per (project, key, value) across the group, for the TagCounter.
  defp tag_counts(batches) do
    Enum.reduce(batches, %{}, fn b, acc ->
      Enum.reduce(b.tag_keys, acc, fn {{k, v}, n}, acc ->
        Map.update(acc, {b.project_id, k, v}, n, &(&1 + n))
      end)
    end)
  end

  # Compare-and-set on last_event_seq fences stale workers (another node or a restart).
  # Batches that set the same columns share one statement: the rows travel as parallel
  # arrays through unnest, and an id missing from RETURNING is a fenced batch. One statement
  # must not touch an invocation twice (the row it would see is undefined), so batches of
  # the same invocation left separate by `Batch.coalesce/1` go in successive rounds.
  defp update_invocations!(units, timeout) do
    now = DateTime.utc_now()

    # Every statement runs before the verdict, so one attempt names every fenced unit of
    # the group and the retry without them is not fenced again by a unit it left in.
    fenced =
      units
      |> Enum.group_by(fn {_key, unit} -> dirty_columns(unit) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {columns, group} ->
        group |> unique_rounds() |> Enum.flat_map(&fenced_update(columns, &1, now, timeout))
      end)

    if fenced != [], do: raise(Fenced, units: fenced)
    :ok
  end

  defp dirty_columns(%Batch{invocation: changes}),
    do: changes |> Map.take(Invocation.ingest_fields()) |> Map.keys() |> Enum.sort()

  # Units in rounds that hold an invocation once each, in order.
  defp unique_rounds([]), do: []

  defp unique_rounds(units) do
    {round, rest, _seen} =
      Enum.reduce(units, {[], [], MapSet.new()}, fn {{id, _n}, _unit} = u, {round, rest, seen} ->
        if MapSet.member?(seen, id),
          do: {round, [u | rest], seen},
          else: {[u | round], rest, MapSet.put(seen, id)}
      end)

    [Enum.reverse(round) | unique_rounds(Enum.reverse(rest))]
  end

  @fixed [{"id", "uuid"}, {"expected", "bigint"}, {"last_seq", "bigint"}, {"now", "timestamptz"}]

  # Returns the keys of the units whose row did not match (fenced). Rows travel in id
  # order: the statement locks the invocation rows in that order on every node.
  defp fenced_update(columns, units, now, timeout) do
    units = Enum.sort_by(units, fn {{id, _n}, _unit} -> Ecto.UUID.dump!(id) end)
    batches = Enum.map(units, &elem(&1, 1))
    typed = Enum.map(columns, &{Atom.to_string(&1), Invocation.__schema__(:type, &1)})

    params =
      [
        Enum.map(batches, &Ecto.UUID.dump!(&1.invocation_id)),
        Enum.map(batches, &(&1.first_seq - 1)),
        Enum.map(batches, & &1.last_seq),
        Enum.map(batches, fn _ -> now end)
      ] ++
        Enum.map(typed, fn {name, type} ->
          col = String.to_existing_atom(name)
          Enum.map(batches, &param_value(Map.get(&1.invocation, col), type))
        end)

    unnest =
      (@fixed ++ Enum.map(typed, fn {name, type} -> {name, array_type(type)} end))
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{_name, type}, i} -> "$#{i}::#{type}[]" end)

    names = Enum.map_join(@fixed ++ typed, ", ", fn {name, _} -> ~s("#{name}") end)

    sets =
      [
        ~s("last_event_seq" = u."last_seq"),
        ~s("last_event_at" = u."now"),
        ~s("updated_at" = u."now")
      ] ++ Enum.map(typed, fn {name, type} -> ~s("#{name}" = #{column_value(name, type)}) end)

    sql = """
    UPDATE "invocations" AS i SET #{Enum.join(sets, ", ")}
    FROM unnest(#{unnest}) AS u(#{names})
    WHERE i."id" = u."id" AND i."last_event_seq" = u."expected"
    RETURNING i."id"
    """

    # A named prepared statement per column set: unnamed statements are parsed and planned
    # on every call (measured: planning cost more than execution).
    name = "conveyor_fenced_update_" <> Base.encode16(:erlang.md5(sql), case: :lower)
    %{rows: rows} = Repo.query!(sql, params, cache_statement: name, timeout: timeout)
    updated = MapSet.new(rows, fn [id] -> id end)

    for {{id, _n} = key, _unit} <- units,
        not MapSet.member?(updated, Ecto.UUID.dump!(id)),
        do: key
  end

  # Element types of the unnest arrays per Ecto type. A list inside an array parameter
  # would be a nested array, so array columns travel as JSON text and are unpacked in SQL.
  defp array_type(:string), do: "text"
  defp array_type(:integer), do: "bigint"
  defp array_type(:boolean), do: "boolean"
  defp array_type(:map), do: "jsonb"
  defp array_type(:utc_datetime_usec), do: "timestamptz"
  defp array_type({:array, :string}), do: "text"

  defp param_value(nil, _type), do: nil
  defp param_value(list, {:array, :string}), do: Jason.encode!(list)
  defp param_value(value, _type), do: value

  defp column_value(name, {:array, :string}),
    do:
      ~s[CASE WHEN u."#{name}" IS NULL THEN NULL ELSE ARRAY(SELECT jsonb_array_elements_text(u."#{name}"::jsonb)) END]

  defp column_value(name, _type), do: ~s(u."#{name}")

  # Rows in one insert_all must share a key set, so group by the fields present and
  # replace exactly those on conflict: partial updates without reading current rows.
  # `keep` columns are written on insert but never replaced.
  defp upsert_grouped(_schema, [], _conflict_target, _keep, _timeout), do: :ok

  # Rows go in conflict-key order: two nodes upserting the same build's rows (a resumed
  # stream whose stale worker's batches are still in a writer's group) then lock them in
  # the same order instead of deadlocking; the linearity run's resend storm retried 507
  # deadlocked group commits on one node (PLAN §25).
  defp upsert_grouped(schema, rows, conflict_target, keep, timeout) do
    rows
    |> Enum.group_by(&(&1 |> Map.keys() |> Enum.sort()))
    |> Enum.each(fn {keys, group} ->
      replace = (keys -- conflict_target) -- keep
      on_conflict = if replace == [], do: :nothing, else: {:replace, replace}
      group = Enum.sort_by(group, &Map.take(&1, conflict_target))

      Repo.insert_all(schema, group,
        on_conflict: on_conflict,
        conflict_target: conflict_target,
        timeout: timeout
      )
    end)
  end

  defp config(key, default), do: Application.get_env(:conveyor, Conveyor.Ingest)[key] || default
end
