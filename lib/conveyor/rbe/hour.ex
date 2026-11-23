defmodule Conveyor.Rbe.Hour do
  @moduledoc """
  The execution-log half of the duplicate-work report for one interval of builds: what
  `Conveyor.Metrics.Rollup` stores per project and hour in `invocation_rollups.rbe`.

  Every spawn of the interval's builds gets its class here, from its own row and the row
  of its key (`action_keys`, looked up by primary key: no other build's spawns are read):

    * `hit`: served from a cache;
    * `first`: the execution of its key that finished first in the scope;
    * `racing` / `racing_x`: it started before the first one finished. `_x`: the first
      one ran in another project of the cache group and this is its own project's first;
    * `seq` / `seq_x`: it started after the first one finished; `_x` again means only
      another project had finished it;
    * `failed`, `uncacheable`: executions no cache could have served;
    * `unkeyed`: an execution without a start time, or parsed before keys existed.

  The class is the SQL form of `Conveyor.ExecLog.ActionKey.classify/4`. All numbers are
  sums of cells `[count, wall ms, core ms, exact wall ms, exact core ms]` per mnemonic,
  so a project's `mnemonic → cores` setting can be applied when the report is read: the
  "exact" part (cores stated by the action's exec properties) is kept apart and never
  overridden.
  """
  import Ecto.Query

  alias Conveyor.ExecLog.{ActionKey, Cores, Spawn}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Projects.Project
  alias Conveyor.Rbe.{Groups, Settings}
  alias Conveyor.Repo

  @timeout :timer.minutes(5)
  @top 50
  @dups ~w(racing racing_x seq seq_x)
  @racing ~w(racing racing_x)
  @sequential ~w(seq seq_x)

  def dups, do: @dups
  def racing, do: @racing
  def sequential, do: @sequential

  @doc "Computes the report of the finished builds `finished` selects; nil when none has spawns."
  @spec compute(Ecto.Query.t()) :: map() | nil
  def compute(finished) do
    case Repo.all(by_mnemonic(finished), timeout: @timeout) do
      [] ->
        nil

      rows ->
        rows
        |> Enum.reduce(%{}, &fold/2)
        |> Map.put("tgt", targets(finished))
        |> Map.merge(builds(finished))
        |> Map.merge(near(finished))
    end
  end

  defp executions(finished) do
    exact = Cores.exact()

    from s in Spawn,
      join: i in subquery(finished),
      on: i.id == s.invocation_id,
      join: p in Project,
      on: p.id == i.project_id,
      left_join: g in Groups,
      on: g.name == fragment("? ->> 'cache_group'", p.settings),
      left_join: kp in ActionKey,
      on: kp.scope == i.project_id and kp.key == s.action_key,
      left_join: kw in ActionKey,
      on: kw.scope == fragment("coalesce(-?, ?)", g.id, i.project_id) and kw.key == s.action_key,
      left_join: hi in Invocation,
      on: hi.id == kw.first_invocation_id,
      left_join: bh in Conveyor.Rbe.Host,
      on: bh.project_id == i.project_id and bh.host == i.host,
      select: %{
        project_id: i.project_id,
        mnemonic: s.mnemonic,
        target_label: s.target_label,
        class:
          fragment(
            """
            CASE WHEN ? THEN 'hit'
                 WHEN ? IS NULL THEN
                   CASE WHEN ? <> 0 OR ? IS NOT NULL THEN 'failed'
                        WHEN ? IS NOT TRUE OR ? IS NOT TRUE THEN 'uncacheable'
                        ELSE 'unkeyed' END
                 WHEN ? IS NULL OR (? = ? AND ? = ?) THEN 'first'
                 WHEN ? < ? THEN
                   CASE WHEN ? IS NOT NULL AND NOT (? = ? AND ? = ?) AND ? < ?
                        THEN 'racing' ELSE 'racing_x' END
                 ELSE
                   CASE WHEN ? IS NOT NULL AND NOT (? = ? AND ? = ?) AND ? >= ?
                        THEN 'seq' ELSE 'seq_x' END
            END
            """,
            s.cache_hit,
            s.action_key,
            s.exit_code,
            s.status,
            s.cacheable,
            s.remote_cacheable,
            kw.key,
            kw.first_invocation_id,
            s.invocation_id,
            kw.first_ordinal,
            s.ordinal,
            s.started_at,
            kw.first_finish,
            kp.key,
            kp.first_invocation_id,
            s.invocation_id,
            kp.first_ordinal,
            s.ordinal,
            s.started_at,
            kp.first_finish,
            kp.key,
            kp.first_invocation_id,
            s.invocation_id,
            kp.first_ordinal,
            s.ordinal,
            s.started_at,
            kp.first_finish
          ),
        source: s.cores_source,
        key_source: s.key_source,
        local: fragment("? IS NOT TRUE", s.remotable),
        # How far the start is from the first one's finish, as the smallest tolerance
        # that covers it (0: none does, or this is the first one).
        band:
          fragment(
            """
            CASE WHEN ? IS NULL OR (? = ? AND ? = ?) THEN 0
                 ELSE (SELECT coalesce(min(t), 0) FROM unnest(?::int[]) t
                       WHERE abs(extract(epoch FROM (? - ?))) <= t) END
            """,
            kw.key,
            kw.first_invocation_id,
            s.invocation_id,
            kw.first_ordinal,
            s.ordinal,
            ^Settings.tolerances(),
            s.started_at,
            kw.first_finish
          ),
        from_project: hi.project_id,
        multi: coalesce(kw.multi, false),
        nondet: coalesce(kw.nondet, false),
        pipeline: fragment("? ->> (? #>> '{rbe,pipeline_key}')", i.tags, p.settings),
        cold: fragment("coalesce(? = ANY(?), false)", i.started_at, bh.firsts),
        ms:
          fragment(
            "CASE WHEN ? THEN 0 ELSE coalesce(?, ?, 0) END",
            s.cache_hit,
            s.exec_ms,
            s.total_ms
          ),
        cores: coalesce(s.cores_milli, 1000),
        exact: fragment("coalesce(? = ?, false)", s.cores_source, ^exact)
      }
  end

  defp by_mnemonic(finished) do
    from x in subquery(executions(finished)),
      group_by: [
        x.project_id,
        x.mnemonic,
        x.class,
        x.source,
        x.key_source,
        x.local,
        x.band,
        x.from_project,
        x.multi,
        x.nondet,
        x.pipeline,
        x.cold
      ],
      select: %{
        project_id: x.project_id,
        mnemonic: x.mnemonic,
        class: x.class,
        source: x.source,
        key_source: x.key_source,
        local: x.local,
        band: x.band,
        from_project: x.from_project,
        multi: x.multi,
        nondet: x.nondet,
        pipeline: x.pipeline,
        cold: x.cold,
        n: count(),
        ms: sum(x.ms),
        core_ms: sum(fragment("?::bigint * ? / 1000", x.ms, x.cores)),
        exact_ms: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", x.exact, x.ms)),
        exact_core_ms:
          sum(
            fragment("CASE WHEN ? THEN ?::bigint * ? / 1000 ELSE 0 END", x.exact, x.ms, x.cores)
          )
      }
  end

  defp cell(r), do: Enum.map([r.n, r.ms, r.core_ms, r.exact_ms, r.exact_core_ms], &int/1)

  defp fold(r, acc) do
    cell = cell(r)
    pid = Integer.to_string(r.project_id)
    executed? = r.class != "hit"

    acc
    |> add(["mn", r.class, r.mnemonic], cell)
    |> add(["proj", pid, r.class, r.mnemonic], cell)
    |> add_if(executed?, ["src", r.mnemonic, Cores.source_name(r.source)], int(r.ms))
    |> add_if(executed?, ["srcn", r.mnemonic, Cores.source_name(r.source)], int(r.n))
    |> add_if(executed? and r.local, ["nonremote", r.mnemonic], cell)
    |> add_if(r.class in @racing and r.local, ["local", r.mnemonic], cell)
    |> add_if(r.class in @dups and r.band > 0, ["band", r.class, "#{r.band}", r.mnemonic], cell)
    |> add_if(r.class in @dups, ["from", pid, origin(r.from_project), r.mnemonic], cell)
    |> add_if(r.multi and r.class in ["first" | @dups], ["multi", pid, r.mnemonic], cell)
    |> add_if(r.nondet and r.class in ["first" | @dups], ["nondet", r.mnemonic], cell)
    |> add_if(
      r.class in @racing and not r.local and is_binary(r.pipeline),
      ["pipe", pid, r.pipeline || "", r.mnemonic],
      cell
    )
    |> add_if(r.class in @sequential and r.cold, ["cold", r.mnemonic], cell)
    |> add_if(not is_nil(r.key_source), ["keys", ActionKey.source_name(r.key_source)], int(r.n))
  end

  defp origin(nil), do: "gone"
  defp origin(id), do: Integer.to_string(id)

  defp add_if(acc, true, path, value), do: add(acc, path, value)
  defp add_if(acc, _false, _path, _value), do: acc

  defp add(acc, [key], value), do: Map.update(acc, key, value, &Conveyor.Rbe.sum(&1, value))

  defp add(acc, [key | rest], value),
    do: Map.put(acc, key, add(Map.get(acc, key, %{}), rest, value))

  # The targets that lost the most core time to duplicates in the interval.
  defp targets(finished) do
    from(x in subquery(executions(finished)),
      where: x.class in @dups,
      group_by: [x.project_id, x.target_label, x.mnemonic, x.class],
      select: %{
        project_id: x.project_id,
        target_label: x.target_label,
        mnemonic: x.mnemonic,
        class: x.class,
        n: count(),
        ms: sum(x.ms),
        core_ms: sum(fragment("?::bigint * ? / 1000", x.ms, x.cores)),
        exact_ms: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", x.exact, x.ms)),
        exact_core_ms:
          sum(
            fragment("CASE WHEN ? THEN ?::bigint * ? / 1000 ELSE 0 END", x.exact, x.ms, x.cores)
          )
      }
    )
    |> Repo.all(timeout: @timeout)
    |> Enum.group_by(&{Integer.to_string(&1.project_id), &1.target_label})
    |> Enum.sort_by(fn {key, rows} -> {-Enum.sum(Enum.map(rows, &int(&1.core_ms))), key} end)
    |> Enum.take(@top)
    |> Enum.reduce(%{}, fn {{pid, label}, rows}, acc ->
      Enum.reduce(rows, acc, &add(&2, [pid, label, &1.class, &1.mnemonic], cell(&1)))
    end)
  end

  # Builds with a parsed log, and what a parallelism bound needs from them: the wall time
  # of their actions against their critical path and their execution phase.
  defp builds(finished) do
    # Joined to the interval's builds inside the aggregate: grouped on its own, the
    # subquery read every spawn of the table for every hour rolled (1.5 s of a 1.75 s
    # roll at 3.3 million spawns; PLAN §27.9).
    per_build =
      from s in Spawn,
        join: i in subquery(finished),
        on: i.id == s.invocation_id,
        where: not s.cache_hit,
        group_by: s.invocation_id,
        select: %{invocation_id: s.invocation_id, ms: sum(coalesce(s.exec_ms, 0))}

    {builds, action_ms, critical_ms, phase_ms, with_path} =
      from(i in subquery(finished),
        join: a in subquery(per_build),
        on: a.invocation_id == i.id,
        select: {
          count(),
          sum(a.ms),
          sum(i.critical_path_ms),
          sum(i.execution_ms),
          count(i.critical_path_ms)
        }
      )
      |> Repo.one(timeout: @timeout)

    logs =
      Repo.one(
        from(i in subquery(finished),
          where: i.exec_log_status in ["parsed", "expired"],
          select: count()
        ),
        timeout: @timeout
      )

    %{
      "builds" => logs,
      "par" => Enum.map([builds, action_ms, critical_ms, phase_ms, with_path], &int/1)
    }
  end

  @near """
  WITH v AS (
    SELECT i.project_id, i.tags ->> 'commit' AS commit, s.target_label, s.mnemonic,
           s.primary_output, s.action_key, count(*) AS n,
           sum(coalesce(s.exec_ms, s.total_ms, 0)) AS ms, min(s.started_at) AS start,
           min(s.invocation_id::text) AS invocation_id
    FROM spawns s JOIN (%FINISHED%) i ON i.id = s.invocation_id
    WHERE s.action_key IS NOT NULL AND i.tags ? 'commit'
    GROUP BY 1, 2, 3, 4, 5, 6
  ), r AS (
    SELECT v.*, rank() OVER w AS variant, first_value(invocation_id) OVER w AS first_invocation
    FROM v WINDOW w AS (PARTITION BY project_id, commit, target_label, mnemonic, primary_output
                        ORDER BY start, action_key)
  )
  SELECT project_id, target_label, mnemonic, n, ms, invocation_id, first_invocation
  FROM r WHERE variant > 1 ORDER BY ms DESC, target_label
  """

  # Near misses: one action slot (target, mnemonic, primary output) at one commit executed
  # under more than one key. Every execution under a later key is a near miss: with equal
  # inputs it would have been a duplicate, and so a possible hit.
  defp near(finished) do
    {sql, params} =
      Repo.to_sql(
        :all,
        from(i in subquery(finished), select: %{id: i.id, project_id: i.project_id, tags: i.tags})
      )

    # The inner query's parameters keep their numbers: this statement adds none.
    %{rows: rows} =
      Repo.query!(String.replace(@near, "%FINISHED%", sql), params, timeout: @timeout)

    examples =
      rows
      |> Enum.take(5)
      |> Enum.map(fn [pid, label, mnemonic, _n, ms, invocation, first] ->
        %{
          "project" => pid,
          "target" => label,
          "mnemonic" => mnemonic,
          "ms" => int(ms),
          "invocation" => invocation,
          "first" => first
        }
      end)

    %{
      "near" => [
        rows |> Enum.map(&int(Enum.at(&1, 3))) |> Enum.sum(),
        rows |> Enum.map(&int(Enum.at(&1, 4))) |> Enum.sum()
      ],
      "near_ex" => examples
    }
  end

  defp int(nil), do: 0
  defp int(%Decimal{} = d), do: d |> Decimal.round() |> Decimal.to_integer()
  defp int(n) when is_float(n), do: round(n)
  defp int(n), do: n
end
