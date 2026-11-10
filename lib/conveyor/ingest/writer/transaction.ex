defmodule Conveyor.Ingest.Writer.Transaction do
  @moduledoc """
  One attempt to commit units: a single transaction, the fence first.

  The fenced invocation updates run before anything else, one statement per set of dirty
  columns (`UPDATE … FROM unnest(...)`, PLAN §24 item 1) with the rows in invocation id
  order. A unit whose row is not where it expects (`last_event_seq = first_seq - 1`) is
  fenced; every statement runs before the verdict, so one attempt names every fenced unit,
  and the transaction rolls back before it has written a child row. The invocation rows
  are therefore the first locks any node's group takes for a build: two groups holding
  the same build queue on its row, and the later one finds itself fenced.

  Then the group is written table by table: one statement per table and column set for
  segments, targets, tests, actions and metrics, keyed rows in conflict-key order.

  `run/3` never raises for a database error: the outcome says what kind it was, which is
  all `Writer.Policy` needs.
  """

  alias Conveyor.Ingest.Batch

  alias Conveyor.Invocations.{
    Action,
    EventSegment,
    Invocation,
    LogSegment,
    Metrics,
    Target,
    TestResult
  }

  alias Conveyor.Ingest.Writer.Plan
  alias Conveyor.Repo

  @target_key [:invocation_id, :label, :aspect]
  @test_key [:invocation_id, :label, :configuration_id, :run, :shard, :attempt]

  @type outcome ::
          :committed
          | {:fenced, [Batch.unit_key()]}
          | {:error, :unavailable | :contention | :data, String.t()}

  @doc """
  Commits `units` (with their keys, in submission order) and the rows planned for them, or
  nothing. `timeout` (ms) bounds the transaction and each of its statements on the client:
  when it is spent the connection is dropped and the server rolls back.

    * `:committed`
    * `{:fenced, keys}`: these units' rows had moved; nothing was written
    * `{:error, class, message}`: nothing was written. `:unavailable` when the database is
      refusing work (no connection, pool exhausted, shutting down, timed out),
      `:contention` when another transaction was in the way (deadlock, serialization
      failure), `:data` for anything else: the database refused these rows
  """
  @spec run([{Batch.unit_key(), Batch.t()}], Plan.t(), pos_integer()) :: outcome()
  def run(units, plan, timeout) do
    case Repo.transaction(fn -> write!(units, plan, timeout) end, timeout: timeout) do
      {:ok, :ok} -> :committed
      {:error, {:fenced, keys}} -> {:fenced, keys}
    end
  rescue
    e -> {:error, error_class(e), Exception.message(e)}
  end

  # What the policy needs to know about a failed transaction: is the database refusing
  # work, is another transaction in the way, or is it this group's rows.
  defp error_class(%DBConnection.ConnectionError{}), do: :unavailable

  # `query_canceled` is how a statement that ran into its timeout comes back (the client
  # cancels it): the database is too slow for this group, which is not the fault of a row.
  # As `:data` it had the group halved, twice as many transactions against a database
  # that could not finish one (7,128 of them in the overload run of PLAN §26.4).
  defp error_class(%Postgrex.Error{postgres: %{code: code}})
       when code in [:too_many_connections, :cannot_connect_now, :admin_shutdown, :query_canceled],
       do: :unavailable

  defp error_class(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, :deadlock_detected],
       do: :contention

  defp error_class(_), do: :data

  defp write!(units, plan, timeout) do
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

    if fenced != [], do: Repo.rollback({:fenced, fenced})
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
end
