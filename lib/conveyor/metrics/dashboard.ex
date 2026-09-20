defmodule Conveyor.Metrics.Dashboard do
  @moduledoc """
  Dashboard panels. Every function takes a `Conveyor.Metrics.Scope` and reads only the
  denormalized invocation columns (plus targets for the failing-targets panel), so panels
  stay fast on large tables: one indexed range scan per panel.
  """
  import Ecto.Query

  alias Conveyor.ExecLog.Spawn
  alias Conveyor.Invocations.{Invocation, Metrics, Target}
  alias Conveyor.Metrics.Scope
  alias Conveyor.Repo

  @type summary :: %{
          builds: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          aborted: non_neg_integer(),
          running: non_neg_integer(),
          other: non_neg_integer(),
          success_rate: float() | nil,
          p50: integer() | nil,
          p90: integer() | nil,
          p99: integer() | nil,
          cache_hit_rate: float() | nil,
          users: non_neg_integer()
        }

  @doc "Headline numbers for a scope."
  @spec summary(Scope.t()) :: summary()
  def summary(scope) do
    counts =
      scope
      |> Scope.base()
      |> group_by([i], i.status)
      |> select([i], {i.status, count(i.id)})
      |> Repo.all()
      |> Map.new()

    finished = Scope.finished(scope)

    {p50, p90, p99, hits, executed, users} =
      finished
      |> select([i], {
        fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", i.duration_ms),
        fragment("percentile_cont(0.9) WITHIN GROUP (ORDER BY ?)", i.duration_ms),
        fragment("percentile_cont(0.99) WITHIN GROUP (ORDER BY ?)", i.duration_ms),
        sum(i.remote_cache_hits),
        sum(i.actions_executed),
        count(i.user_name, :distinct)
      })
      |> Repo.one()

    succeeded = Map.get(counts, "succeeded", 0)
    failed = Map.get(counts, "failed", 0)
    aborted = Map.get(counts, "aborted", 0)
    verdicts = succeeded + failed

    %{
      builds: counts |> Map.values() |> Enum.sum(),
      succeeded: succeeded,
      failed: failed,
      aborted: aborted,
      running: Map.get(counts, "in_progress", 0),
      other: Map.get(counts, "disconnected", 0) + Map.get(counts, "unknown", 0),
      success_rate: if(verdicts > 0, do: succeeded / verdicts, else: nil),
      p50: to_ms(p50),
      p90: to_ms(p90),
      p99: to_ms(p99),
      cache_hit_rate: rate(hits, executed),
      users: users || 0
    }
  end

  @delta_keys [:builds, :success_rate, :p50, :p90, :p99, :cache_hit_rate]

  @doc """
  Relative change of each headline number from `previous` to `current`, as a fraction
  (`0.25` = up 25 %). `nil` when either side has no value or the previous value is zero.
  Rates compare as absolute differences in percentage points would mislead, so they are
  relative too: a success rate going 80 % → 90 % is `+0.125`.
  """
  @spec deltas(summary(), summary()) :: %{
          builds: float() | nil,
          success_rate: float() | nil,
          p50: float() | nil,
          p90: float() | nil,
          p99: float() | nil,
          cache_hit_rate: float() | nil
        }
  def deltas(current, previous) do
    Map.new(@delta_keys, fn key -> {key, delta(Map.get(current, key), Map.get(previous, key))} end)
  end

  defp delta(nil, _previous), do: nil
  defp delta(_current, nil), do: nil
  defp delta(_current, previous) when previous == 0, do: nil
  defp delta(current, previous), do: (current - previous) / previous

  @doc """
  Per-bucket series: build counts by status, duration percentiles and cache hit rate.
  Buckets are contiguous over the scope's window (empty buckets are filled in).
  """
  @spec series(Scope.t()) :: [map()]
  def series(scope) do
    bucket = Scope.bucket(scope)

    rows =
      scope
      |> Scope.base()
      |> bucketed(bucket)
      |> select_merge([i], %{
        succeeded: fragment("count(*) FILTER (WHERE ? = 'succeeded')", i.status),
        failed: fragment("count(*) FILTER (WHERE ? = 'failed')", i.status),
        other: fragment("count(*) FILTER (WHERE ? NOT IN ('succeeded', 'failed'))", i.status),
        p50:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? IN ('succeeded','failed','aborted'))",
            i.duration_ms,
            i.status
          ),
        p90:
          fragment(
            "percentile_cont(0.9) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? IN ('succeeded','failed','aborted'))",
            i.duration_ms,
            i.status
          ),
        p99:
          fragment(
            "percentile_cont(0.99) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? IN ('succeeded','failed','aborted'))",
            i.duration_ms,
            i.status
          ),
        hits: sum(i.remote_cache_hits),
        executed: sum(i.actions_executed)
      })
      |> Repo.all()
      |> Map.new(&{to_utc(&1.bucket), &1})

    for b <- buckets(scope.from, scope.to, bucket) do
      case Map.get(rows, b) do
        nil ->
          %{
            bucket: b,
            succeeded: 0,
            failed: 0,
            other: 0,
            p50: nil,
            p90: nil,
            p99: nil,
            cache_hit_rate: nil
          }

        r ->
          %{
            bucket: b,
            succeeded: r.succeeded,
            failed: r.failed,
            other: r.other,
            p50: to_ms(r.p50),
            p90: to_ms(r.p90),
            p99: to_ms(r.p99),
            cache_hit_rate: rate(r.hits, r.executed)
          }
      end
    end
  end

  @doc """
  Where action time went per bucket: the `action_phases` of every finished build's profile
  summary, summed by phase name (milliseconds). Each row is `%{bucket: dt, "cache check" => ms, …}`
  with only the phases present; buckets without profiles are filled in empty.
  """
  @spec phases_over_time(Scope.t()) :: [map()]
  def phases_over_time(scope) do
    bucket = Scope.bucket(scope)

    rows =
      scope
      |> Scope.finished()
      |> join(:inner, [i], m in Metrics, on: m.invocation_id == i.id)
      |> join(
        :inner,
        [i, m],
        p in fragment("jsonb_array_elements(? -> 'action_phases')", m.profile_summary),
        on: true
      )
      |> phase_buckets(bucket)
      |> Repo.all()
      |> Enum.group_by(&to_utc(elem(&1, 0)), fn {_, name, ms} -> {name, round(to_number(ms))} end)

    for b <- buckets(scope.from, scope.to, bucket),
        do: Map.merge(%{bucket: b}, Map.new(Map.get(rows, b, [])))
  end

  @doc "Failed builds grouped by Bazel exit code name."
  @spec failure_breakdown(Scope.t()) :: [{String.t(), non_neg_integer()}]
  def failure_breakdown(scope) do
    scope
    |> Scope.base()
    |> where([i], i.status in ["failed", "aborted", "disconnected", "unknown"])
    |> group_by([i], [i.status, i.exit_code_name])
    |> select([i], {coalesce(i.exit_code_name, i.status), count(i.id)})
    |> order_by([i], desc: count(i.id))
    |> Repo.all()
  end

  @doc "Where actions ran: remote cache hits vs remote vs local vs worker vs sandbox."
  @spec strategy_mix(Scope.t()) :: [{String.t(), non_neg_integer()}]
  def strategy_mix(scope) do
    {hits, remote, local, worker, sandbox} =
      scope
      |> Scope.finished()
      |> select(
        [i],
        {sum(i.remote_cache_hits), sum(i.remote_exec), sum(i.local_exec), sum(i.worker_exec),
         sum(i.sandbox_exec)}
      )
      |> Repo.one()

    [
      {"remote cache hit", hits},
      {"remote", remote},
      {"worker", worker},
      {"sandbox", sandbox},
      {"local", local}
    ]
    |> Enum.map(fn {k, v} -> {k, round(to_number(v || 0))} end)
    |> Enum.reject(fn {_, v} -> v == 0 end)
  end

  @doc "Builds and failures per user, busiest first."
  @spec by_user(Scope.t(), pos_integer()) :: [map()]
  def by_user(scope, limit \\ 10) do
    scope
    |> Scope.base()
    |> where([i], not is_nil(i.user_name))
    |> group_by([i], i.user_name)
    |> select([i], %{
      user: i.user_name,
      builds: count(i.id),
      failed: fragment("count(*) FILTER (WHERE ? = 'failed')", i.status),
      p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", i.duration_ms)
    })
    |> order_by([i], desc: count(i.id))
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&%{&1 | p50: to_ms(&1.p50)})
  end

  @doc "Slowest finished builds."
  @spec slowest_builds(Scope.t(), pos_integer()) :: [Conveyor.Invocations.Invocation.t()]
  def slowest_builds(scope, limit \\ 10) do
    scope
    |> Scope.finished()
    |> where([i], not is_nil(i.duration_ms))
    |> order_by([i], desc: i.duration_ms)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Bazel version distribution."
  @spec versions(Scope.t()) :: [{String.t(), non_neg_integer()}]
  def versions(scope) do
    scope
    |> Scope.base()
    |> where([i], not is_nil(i.bazel_version))
    |> group_by([i], i.bazel_version)
    |> select([i], {i.bazel_version, count(i.id)})
    |> order_by([i], desc: count(i.id))
    |> Repo.all()
  end

  @doc "Targets that failed most often across builds in scope."
  @spec top_failing_targets(Scope.t(), pos_integer()) :: [map()]
  def top_failing_targets(scope, limit \\ 10) do
    ids = scope |> Scope.base() |> select([i], i.id)

    Target
    |> where([t], t.invocation_id in subquery(ids))
    |> where([t], t.status == "failed" or t.test_status in ["FAILED", "TIMEOUT"])
    |> group_by([t], t.label)
    |> select([t], %{
      label: t.label,
      failures: count(t.id),
      last_invocation_id: fragment("max(?::text)", t.invocation_id)
    })
    |> order_by([t], desc: count(t.id))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  When builds start: a 7 × 24 grid of counts by ISO weekday (1 = Monday) and UTC hour.
  Returns `{weekday, hour, count}` for every cell (zeros included).
  """
  @spec starts_heatmap(Scope.t()) :: [{1..7, 0..23, non_neg_integer()}]
  def starts_heatmap(scope) do
    rows =
      scope
      |> Scope.base()
      |> group_by([i], [
        fragment("extract(isodow from ?)::int", i.started_at),
        fragment("extract(hour from ?)::int", i.started_at)
      ])
      |> select([i], {
        {fragment("extract(isodow from ?)::int", i.started_at),
         fragment("extract(hour from ?)::int", i.started_at)},
        count(i.id)
      })
      |> Repo.all()
      |> Map.new()

    for d <- 1..7, h <- 0..23, do: {d, h, Map.get(rows, {d, h}, 0)}
  end

  @doc """
  Targets whose median duration in the scope rose more than `threshold` (a fraction, default
  0.2) against the previous period, with at least `min_runs` timed runs on both sides.
  Sorted by the ratio, largest first.
  """
  @spec target_regressions(Scope.t(), keyword()) :: [map()]
  def target_regressions(scope, opts \\ []) do
    factor = 1.0 + Keyword.get(opts, :threshold, 0.2)
    min_runs = Keyword.get(opts, :min_runs, 3)
    limit = Keyword.get(opts, :limit, 10)
    current = target_medians(scope)
    previous = target_medians(Scope.previous(scope))

    from(c in subquery(current),
      join: p in subquery(previous),
      on: c.label == p.label,
      where: c.runs >= ^min_runs and p.runs >= ^min_runs and p.p50 > 0,
      where: c.p50 > p.p50 * type(^factor, :float),
      order_by: [desc: fragment("? / ?", c.p50, p.p50)],
      limit: ^limit,
      select: %{
        label: c.label,
        p50: c.p50,
        previous_p50: p.p50,
        runs: c.runs,
        previous_runs: p.runs
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | p50: to_ms(&1.p50), previous_p50: to_ms(&1.previous_p50)})
  end

  defp target_medians(scope) do
    ids = scope |> Scope.finished() |> select([i], i.id)

    Target
    |> where([t], t.invocation_id in subquery(ids))
    |> where([t], not is_nil(t.duration_ms) and t.status == "success")
    |> group_by([t], t.label)
    |> select([t], %{
      label: t.label,
      runs: count(t.id),
      p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)::float", t.duration_ms)
    })
  end

  @doc """
  Queue time per bucket as an RBE capacity signal: the "queued" phase total divided by the
  number of profiled builds in the bucket (ms per build; `nil` without profiles).
  """
  @spec queue_trend(Scope.t()) :: [%{bucket: DateTime.t(), queued: integer() | nil}]
  def queue_trend(scope) do
    bucket = Scope.bucket(scope)

    rows =
      scope
      |> Scope.finished()
      |> join(:inner, [i], m in Metrics, on: m.invocation_id == i.id)
      |> join(
        :inner,
        [i, m],
        p in fragment("jsonb_array_elements(? -> 'action_phases')", m.profile_summary),
        on: true
      )
      |> queue_buckets(bucket)
      |> Repo.all()
      |> Map.new(fn {b, queued, builds} ->
        {to_utc(b), round(to_number(queued || 0) / max(builds, 1))}
      end)

    for b <- buckets(scope.from, scope.to, bucket), do: %{bucket: b, queued: Map.get(rows, b)}
  end

  @doc """
  Work by action mnemonic across the scope: actions created and executed (from Bazel's
  action summary) and action time (from profile summaries when present), busiest first.
  """
  @spec actions_by_mnemonic(Scope.t(), pos_integer()) :: [map()]
  def actions_by_mnemonic(scope, limit \\ 10) do
    base =
      scope |> Scope.finished() |> join(:inner, [i], m in Metrics, on: m.invocation_id == i.id)

    counts =
      base
      |> join(
        :inner,
        [i, m],
        a in fragment(
          "jsonb_array_elements(? -> 'actionSummary' -> 'actionData')",
          m.build_metrics
        ),
        on: true
      )
      |> group_by([i, m, a], fragment("? ->> 'mnemonic'", a))
      |> select([i, m, a], {
        fragment("? ->> 'mnemonic'", a),
        sum(fragment("coalesce((? ->> 'actionsCreated')::bigint, 0)", a)),
        sum(fragment("coalesce((? ->> 'actionsExecuted')::bigint, 0)", a))
      })
      |> Repo.all()

    time =
      base
      |> join(
        :inner,
        [i, m],
        p in fragment("jsonb_array_elements(? -> 'mnemonics')", m.profile_summary),
        on: true
      )
      |> group_by([i, m, p], fragment("? ->> 'name'", p))
      |> select(
        [i, m, p],
        {fragment("? ->> 'name'", p), sum(fragment("(? ->> 'total_ms')::float", p))}
      )
      |> Repo.all()
      |> Map.new(fn {name, ms} -> {name, round(to_number(ms))} end)

    counts
    |> Enum.map(fn {name, created, executed} ->
      %{
        mnemonic: name,
        created: round(to_number(created)),
        executed: round(to_number(executed)),
        time_ms: Map.get(time, name)
      }
    end)
    |> Enum.sort_by(&{-&1.executed, &1.mnemonic})
    |> Enum.take(limit)
  end

  # --- execution log reports (spawns) ---------------------------------------------------------

  @doc "Remote cache hit rate per mnemonic across the scope's execution logs, busiest first."
  @spec cache_by_mnemonic(Scope.t(), pos_integer()) :: [map()]
  def cache_by_mnemonic(scope, limit \\ 10) do
    scope
    |> spawns()
    |> group_by([s], s.mnemonic)
    |> select([s], %{
      mnemonic: s.mnemonic,
      spawns: count(s.id),
      hits: fragment("count(*) FILTER (WHERE ?)", s.cache_hit)
    })
    |> order_by([s], desc: count(s.id), asc: s.mnemonic)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :hit_rate, &1.hits / &1.spawns))
  end

  @doc "Targets whose spawns missed the remote cache most often (executed instead)."
  @spec top_cache_missing_targets(Scope.t(), pos_integer()) :: [map()]
  def top_cache_missing_targets(scope, limit \\ 10) do
    scope
    |> spawns()
    |> where([s], not s.cache_hit)
    |> group_by([s], s.target_label)
    |> select([s], %{label: s.target_label, misses: count(s.id)})
    |> order_by([s], desc: count(s.id), asc: s.target_label)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Non-hermetic actions: spawns in the scope whose inputs are identical (same digest) to an
  earlier spawn of the same action in another build of the project, but whose outputs
  differ. Grouped by target and mnemonic, most occurrences first.
  """
  @spec non_hermetic(Scope.t(), pos_integer()) :: [map()]
  def non_hermetic(scope, limit \\ 10) do
    scope
    |> spawns()
    |> join(:inner, [s, i], p in Spawn,
      on:
        p.inputs_digest == s.inputs_digest and p.target_label == s.target_label and
          p.mnemonic == s.mnemonic and p.primary_output == s.primary_output and
          p.invocation_id != s.invocation_id and p.id < s.id and
          p.outputs_digest != s.outputs_digest
    )
    |> join(:inner, [s, i, p], pi in Invocation,
      on: pi.id == p.invocation_id and pi.project_id == i.project_id
    )
    |> group_by([s], [s.target_label, s.mnemonic])
    |> select([s], %{label: s.target_label, mnemonic: s.mnemonic, count: count(s.id, :distinct)})
    |> order_by([s], desc: count(s.id, :distinct), asc: s.target_label)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Remote traffic per bucket estimated from execution logs: bytes of inputs sent for remote
  executions (`runner` "remote", not a cache hit) and bytes of outputs fetched (cache hits
  and remote executions). `nil` for buckets without logs.
  """
  @spec remote_bytes(Scope.t()) :: [map()]
  def remote_bytes(scope) do
    bucket = Scope.bucket(scope)

    rows =
      scope
      |> spawns()
      |> remote_buckets(bucket)
      |> Repo.all()
      |> Map.new(fn {b, sent, fetched} ->
        {to_utc(b), {round(to_number(sent || 0)), round(to_number(fetched || 0))}}
      end)

    for b <- buckets(scope.from, scope.to, bucket) do
      case Map.get(rows, b) do
        nil -> %{bucket: b, sent: nil, fetched: nil}
        {sent, fetched} -> %{bucket: b, sent: sent, fetched: fetched}
      end
    end
  end

  defp spawns(scope) do
    Spawn |> join(:inner, [s], i in subquery(Scope.finished(scope)), on: i.id == s.invocation_id)
  end

  defp remote_buckets(query, :hour) do
    query
    |> group_by([s, i], fragment("date_trunc('hour', ?)", i.started_at))
    |> select([s, i], {
      fragment("date_trunc('hour', ?)", i.started_at),
      sum(s.input_bytes) |> filter(s.runner == "remote" and not s.cache_hit),
      sum(s.output_bytes) |> filter(s.runner == "remote" or s.cache_hit)
    })
  end

  defp remote_buckets(query, :day) do
    query
    |> group_by([s, i], fragment("date_trunc('day', ?)", i.started_at))
    |> select([s, i], {
      fragment("date_trunc('day', ?)", i.started_at),
      sum(s.input_bytes) |> filter(s.runner == "remote" and not s.cache_hit),
      sum(s.output_bytes) |> filter(s.runner == "remote" or s.cache_hit)
    })
  end

  # --- helpers -------------------------------------------------------------------------------

  # The unit must be a literal: a bound parameter would make GROUP BY and SELECT differ.
  defp bucketed(query, :hour) do
    query
    |> group_by([i], fragment("date_trunc('hour', ?)", i.started_at))
    |> select([i], %{bucket: fragment("date_trunc('hour', ?)", i.started_at)})
  end

  defp bucketed(query, :day) do
    query
    |> group_by([i], fragment("date_trunc('day', ?)", i.started_at))
    |> select([i], %{bucket: fragment("date_trunc('day', ?)", i.started_at)})
  end

  defp phase_buckets(query, :hour) do
    query
    |> group_by([i, m, p], [
      fragment("date_trunc('hour', ?)", i.started_at),
      fragment("? ->> 'name'", p)
    ])
    |> select([i, m, p], {
      fragment("date_trunc('hour', ?)", i.started_at),
      fragment("? ->> 'name'", p),
      sum(fragment("(? ->> 'total_ms')::float", p))
    })
  end

  defp phase_buckets(query, :day) do
    query
    |> group_by([i, m, p], [
      fragment("date_trunc('day', ?)", i.started_at),
      fragment("? ->> 'name'", p)
    ])
    |> select([i, m, p], {
      fragment("date_trunc('day', ?)", i.started_at),
      fragment("? ->> 'name'", p),
      sum(fragment("(? ->> 'total_ms')::float", p))
    })
  end

  defp queue_buckets(query, :hour) do
    query
    |> group_by([i], fragment("date_trunc('hour', ?)", i.started_at))
    |> select([i, m, p], {
      fragment("date_trunc('hour', ?)", i.started_at),
      sum(fragment("(? ->> 'total_ms')::float", p))
      |> filter(fragment("? ->> 'name' = 'queued'", p)),
      count(i.id, :distinct)
    })
  end

  defp queue_buckets(query, :day) do
    query
    |> group_by([i], fragment("date_trunc('day', ?)", i.started_at))
    |> select([i, m, p], {
      fragment("date_trunc('day', ?)", i.started_at),
      sum(fragment("(? ->> 'total_ms')::float", p))
      |> filter(fragment("? ->> 'name' = 'queued'", p)),
      count(i.id, :distinct)
    })
  end

  defp buckets(from, to, unit) do
    step = if unit == :hour, do: 3_600, else: 86_400
    first = truncate(from, unit)

    Stream.iterate(first, &DateTime.add(&1, step, :second))
    |> Enum.take_while(&(DateTime.compare(&1, to) == :lt))
  end

  defp truncate(%DateTime{} = dt, :hour), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}

  defp truncate(%DateTime{} = dt, :day),
    do: %{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp to_utc(%NaiveDateTime{} = n),
    do: n |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp to_utc(%DateTime{} = d), do: DateTime.truncate(d, :second)

  defp to_ms(nil), do: nil
  defp to_ms(%Decimal{} = d), do: d |> Decimal.to_float() |> round()
  defp to_ms(f) when is_float(f), do: round(f)
  defp to_ms(n) when is_integer(n), do: n

  defp rate(_hits, nil), do: nil
  defp rate(_hits, 0), do: nil
  defp rate(nil, _executed), do: nil
  defp rate(hits, executed), do: to_number(hits) / to_number(executed)

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(n), do: n
end
