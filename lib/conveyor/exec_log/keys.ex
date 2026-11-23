defmodule Conveyor.ExecLog.Keys do
  @moduledoc """
  Maintains `action_keys` when a log is stored (`Conveyor.ExecLog.store!/2`), inside the
  store's transaction.

  `merge!/4` is the path of every parse: the log's executions are reduced to one entry per
  key, existing rows are locked **in key order** (the order every parser uses, so two
  parsers sharing keys queue instead of deadlocking), and one upsert per chunk takes the
  minimum; a row the log changes nothing about is not written again (`last_finish` is kept
  to the day for that: the hundredth execution of a key on one day costs a lock, not a
  new row version). It returns the keys whose first execution or flags changed for executions that
  were already stored: the builds that hold those executions are the hours a rollup has to
  compute again.

  `rebuild!/3` is the path of a re-uploaded log whose content differs: the old content's
  contribution cannot be subtracted from a minimum, so the rows of the keys involved are
  recomputed from the executions still stored.

  Nothing here classifies an execution. The class is a function of the execution and its
  key's row (`Conveyor.ExecLog.ActionKey.classify/3`), evaluated when an hour is rolled,
  so no stored class can be left behind by a later, earlier-finishing arrival.
  """
  import Ecto.Query

  alias Conveyor.ExecLog.{ActionKey, Spawn}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo

  @chunk 5_000
  @timeout :timer.minutes(5)

  @doc """
  One entry per key of a log: its earliest finisher, its last finish, the outputs seen.
  Sorted by key.
  """
  @spec entries([map()], String.t()) :: [map()]
  def entries(spawns, invocation_id) do
    spawns
    |> Enum.filter(&ActionKey.execution?/1)
    |> Enum.group_by(& &1.action_key)
    |> Enum.map(fn {key, execs} ->
      first = Enum.min_by(execs, &ActionKey.rank(&1, invocation_id))
      outs = execs |> Enum.map(&out_prefix/1) |> Enum.uniq()

      %{
        key: key,
        finish: ActionKey.finish(first),
        start: first.started_at,
        ordinal: first.ordinal,
        last_finish: execs |> Enum.map(&ActionKey.finish/1) |> Enum.max(DateTime),
        out: hd(outs),
        nondet: length(outs) > 1
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp out_prefix(%{outputs_digest: d}), do: binary_part(d, 0, 16)

  @doc """
  Merges a log's entries into the project's rows. Returns the keys that already had
  executions and whose first execution, `multi` or `nondet` changed.
  """
  @spec merge!(integer(), String.t(), integer(), [map()]) :: [binary()]
  def merge!(scope, invocation_id, project_id, entries) do
    scope_lock!(scope, :shared)

    entries
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(&merge_chunk(scope, invocation_id, project_id, &1))
  end

  @less "(EXCLUDED.first_finish, EXCLUDED.first_start, EXCLUDED.first_invocation_id, EXCLUDED.first_ordinal) < (k.first_finish, k.first_start, k.first_invocation_id, k.first_ordinal)"

  @merge """
  INSERT INTO action_keys AS k
    (scope, key, first_finish, first_start, first_invocation_id, first_ordinal,
     last_finish, grp, multi, out, nondet)
  SELECT $1::bigint, t.key, t.finish, t.start, $2::uuid, t.ordinal,
         date_trunc('day', t.last_finish),
         $3::bigint, false, ('x' || t.out)::bit(64)::bigint, t.nondet
  FROM unnest($4::bytea[], $5::timestamp[], $6::timestamp[], $7::int[],
              $8::timestamp[], $9::text[], $10::bool[])
       AS t(key, finish, start, ordinal, last_finish, out, nondet)
  ORDER BY t.key
  ON CONFLICT (scope, key) DO UPDATE SET
    first_finish = CASE WHEN #{@less} THEN EXCLUDED.first_finish ELSE k.first_finish END,
    first_start = CASE WHEN #{@less} THEN EXCLUDED.first_start ELSE k.first_start END,
    first_invocation_id =
      CASE WHEN #{@less} THEN EXCLUDED.first_invocation_id ELSE k.first_invocation_id END,
    first_ordinal = CASE WHEN #{@less} THEN EXCLUDED.first_ordinal ELSE k.first_ordinal END,
    last_finish = GREATEST(k.last_finish, EXCLUDED.last_finish),
    grp = COALESCE(k.grp, EXCLUDED.grp),
    multi = k.multi OR (k.grp IS NOT NULL AND EXCLUDED.grp IS NOT NULL AND k.grp <> EXCLUDED.grp),
    out = COALESCE(k.out, EXCLUDED.out),
    nondet = k.nondet OR EXCLUDED.nondet OR (k.out IS NOT NULL AND k.out <> EXCLUDED.out)
  WHERE #{@less}
     OR EXCLUDED.last_finish > k.last_finish
     OR (k.grp IS NULL AND EXCLUDED.grp IS NOT NULL)
     OR (NOT k.multi AND k.grp IS NOT NULL AND EXCLUDED.grp IS NOT NULL AND k.grp <> EXCLUDED.grp)
     OR (k.out IS NULL AND EXCLUDED.out IS NOT NULL)
     OR (NOT k.nondet AND (EXCLUDED.nondet OR (k.out IS NOT NULL AND k.out <> EXCLUDED.out)))
  RETURNING k.key, k.first_invocation_id, k.first_ordinal, k.multi, k.nondet, (k.xmax::text <> '0')
  """

  defp merge_chunk(scope, invocation_id, project_id, entries) do
    holder = Ecto.UUID.dump!(invocation_id)
    seen = read_rows(scope, Enum.map(entries, & &1.key))

    # A row only ever moves one way (an earlier first, a later last day, a flag that
    # turns true), so an entry that would change nothing in the row as it was read
    # changes nothing in the row as it is by now: it is left out, and its row is not
    # locked. Most executions of a group are of this kind (the 360th build of a shared
    # library); locking their rows made four parsers wait for each other 12 % of their
    # time (PLAN §27.9). `rebuild!`, the one writer that moves a row the other way,
    # excludes merges with the scope's advisory lock.
    case Enum.reject(entries, &settled?(&1, Map.get(seen, &1.key), holder, project_id)) do
      [] ->
        []

      entries ->
        keys = Enum.map(entries, & &1.key)
        lock_rows(scope, Enum.filter(keys, &Map.has_key?(seen, &1)))

        %{rows: rows} =
          Repo.query!(
            @merge,
            [
              scope,
              holder,
              project_id,
              keys,
              Enum.map(entries, & &1.finish),
              Enum.map(entries, & &1.start),
              Enum.map(entries, & &1.ordinal),
              Enum.map(entries, & &1.last_finish),
              Enum.map(entries, & &1.out),
              Enum.map(entries, & &1.nondet)
            ],
            timeout: @timeout
          )

        for [key, first, ordinal, multi, nondet, existed] <- rows,
            existed,
            # Against the row as it was read: one that another parser inserted or changed
            # since counts as changed, which at worst rolls an hour once more.
            before(Map.get(seen, key)) != {first, ordinal, multi, nondet},
            do: key
    end
  end

  defp before(nil), do: nil

  defp before(%ActionKey{} = row),
    do: {Ecto.UUID.dump!(row.first_invocation_id), row.first_ordinal, row.multi, row.nondet}

  # True when merging the entry cannot change the row: the conditions of the upsert's
  # WHERE, evaluated here.
  defp settled?(_entry, nil, _holder, _project_id), do: false

  defp settled?(entry, %ActionKey{} = row, holder, project_id) do
    <<out::signed-64>> = Base.decode16!(entry.out, case: :mixed)

    first =
      {DateTime.to_unix(row.first_finish, :microsecond),
       DateTime.to_unix(row.first_start, :microsecond), Ecto.UUID.dump!(row.first_invocation_id),
       row.first_ordinal}

    mine =
      {DateTime.to_unix(entry.finish, :microsecond), DateTime.to_unix(entry.start, :microsecond),
       holder, entry.ordinal}

    mine >= first and
      Date.compare(DateTime.to_date(entry.last_finish), DateTime.to_date(row.last_finish)) != :gt and
      row.grp != nil and (row.multi or row.grp == project_id) and
      row.out != nil and (row.nondet or (not entry.nondet and row.out == out))
  end

  defp read_rows(scope, keys) do
    from(k in ActionKey, where: k.scope == ^scope and k.key in ^keys)
    |> Repo.all(timeout: @timeout)
    |> Map.new(&{&1.key, &1})
  end

  # Existing rows, locked in key order.
  defp lock_rows(_scope, []), do: :ok

  defp lock_rows(scope, keys) do
    from(k in ActionKey,
      where: k.scope == ^scope and k.key in ^keys,
      order_by: k.key,
      lock: "FOR UPDATE",
      select: k.key
    )
    |> Repo.all(timeout: @timeout)

    :ok
  end

  # Merges of a scope share this lock; a rebuild of the scope takes it alone.
  defp scope_lock!(scope, mode) do
    function =
      if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

    Repo.query!(
      "SELECT #{function}(hashtextextended('action_keys:' || $1::text, 0))",
      [Integer.to_string(scope)],
      timeout: @timeout
    )
  end

  @rebuild """
  WITH e AS (
    SELECT s.action_key AS key, s.started_at AS start,
           s.started_at + coalesce(s.total_ms, s.exec_ms, 0) * interval '1 millisecond' AS finish,
           s.invocation_id, s.ordinal,
           i.project_id AS grp,
           ('x' || substr(s.outputs_digest, 1, 16))::bit(64)::bigint AS out
    FROM spawns s JOIN invocations i ON i.id = s.invocation_id
    WHERE i.project_id = ANY($3::bigint[]) AND s.action_key = ANY($2::bytea[])
  ), firsts AS (
    SELECT DISTINCT ON (key) key, finish, start, invocation_id, ordinal
    FROM e ORDER BY key, finish, start, invocation_id, ordinal
  ), sums AS (
    SELECT key, date_trunc('day', max(finish)) AS last_finish, min(grp) AS grp, count(DISTINCT grp) > 1 AS multi,
           min(out) AS out, count(DISTINCT out) > 1 AS nondet
    FROM e GROUP BY key
  )
  INSERT INTO action_keys AS k
    (scope, key, first_finish, first_start, first_invocation_id, first_ordinal,
     last_finish, grp, multi, out, nondet)
  SELECT $1::bigint, f.key, f.finish, f.start, f.invocation_id, f.ordinal,
         s.last_finish, s.grp, s.multi, s.out, s.nondet
  FROM firsts f JOIN sums s USING (key)
  ORDER BY f.key
  ON CONFLICT (scope, key) DO UPDATE SET
    first_finish = EXCLUDED.first_finish, first_start = EXCLUDED.first_start,
    first_invocation_id = EXCLUDED.first_invocation_id, first_ordinal = EXCLUDED.first_ordinal,
    last_finish = EXCLUDED.last_finish, grp = EXCLUDED.grp, multi = EXCLUDED.multi,
    out = EXCLUDED.out, nondet = EXCLUDED.nondet
  """

  @doc """
  Recomputes a scope's rows of `keys` from the executions its projects have stored (rows
  without one are deleted). Returns the keys, sorted: every build holding one of them is
  to be rolled again.
  """
  @spec rebuild!(integer(), [integer()], [binary()]) :: [binary()]
  def rebuild!(scope, project_ids, keys) do
    keys = keys |> Enum.uniq() |> Enum.sort()
    scope_lock!(scope, :exclusive)

    Enum.each(Enum.chunk_every(keys, @chunk), fn chunk ->
      lock_rows(scope, chunk)
      Repo.query!(@rebuild, [scope, chunk, project_ids], timeout: @timeout)

      from(k in ActionKey, as: :key)
      |> where([k], k.scope == ^scope and k.key in ^chunk)
      |> where([k], not exists(executions_of_key(project_ids)))
      |> Repo.delete_all(timeout: @timeout)
    end)

    keys
  end

  defp executions_of_key(project_ids) do
    from s in Spawn,
      join: i in Invocation,
      on: i.id == s.invocation_id,
      where: s.action_key == parent_as(:key).key and i.project_id in ^project_ids,
      select: 1
  end

  @doc "The builds of the projects, other than `except`, that hold an execution of one of `keys`."
  @spec holders([integer()], [binary()], String.t()) :: [String.t()]
  def holders(_project_ids, [], _except), do: []

  def holders(project_ids, keys, except) do
    # In two steps, each with one possible plan: by key through the partial index of
    # `spawns`, then the builds of these projects among what that found. As one join the
    # statement averaged 52 ms under four parsers (PLAN §27.9).
    ids =
      keys
      |> Enum.uniq()
      |> Enum.chunk_every(@chunk)
      |> Enum.flat_map(fn chunk ->
        Repo.all(
          from(s in Spawn,
            where: s.action_key in ^chunk,
            distinct: true,
            select: s.invocation_id
          ),
          timeout: @timeout
        )
      end)
      |> Enum.uniq()
      |> List.delete(except)

    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from(i in Invocation,
          where: i.id in ^chunk and i.project_id in ^project_ids,
          select: i.id
        ),
        timeout: @timeout
      )
    end)
  end

  @doc """
  Moves `updated_at` of the builds forward, rows locked in id order. A rollup row is stale
  when it is older than a build of its hour (docs/spec/Rollup.tla); this is the last
  statement of the store's transaction, so the stamp is as close to the commit as the
  rollup's margin assumes.
  """
  @spec touch!([String.t()], DateTime.t()) :: :ok
  def touch!(invocation_ids, now) do
    ids = invocation_ids |> Enum.uniq() |> Enum.sort()

    locked =
      from(i in Invocation, where: i.id in ^ids, order_by: i.id, lock: "FOR UPDATE", select: i.id)

    Repo.update_all(
      from(i in Invocation, where: i.id in subquery(locked)),
      [set: [updated_at: now]],
      timeout: @timeout
    )

    :ok
  end

  @doc """
  Deletes a scope's rows whose last execution finished before `cutoff` (`last_finish` is
  the day of that finish, so callers leave two days of margin): every execution of such a
  key belongs to a build older than the spawn retention, whose hours are frozen.
  A key forgotten this way starts over: its next execution is a first one, as it would be
  for a cache that evicted the entry.
  """
  @spec prune!(integer(), DateTime.t()) :: non_neg_integer()
  def prune!(scope, cutoff) do
    {n, _} =
      Repo.delete_all(
        from(k in ActionKey, where: k.scope == ^scope and k.last_finish < ^cutoff),
        timeout: @timeout
      )

    n
  end

  @doc "Deletes rows of scopes that no longer exist once they are older than `cutoff`."
  @spec prune_orphans!([integer()], DateTime.t()) :: non_neg_integer()
  def prune_orphans!(live_scopes, cutoff) do
    {n, _} =
      Repo.delete_all(
        from(k in ActionKey, where: k.scope not in ^live_scopes and k.last_finish < ^cutoff),
        timeout: @timeout
      )

    n
  end
end
