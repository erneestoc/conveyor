defmodule Conveyor.Metrics.Rollup do
  @moduledoc """
  Hourly per-project rollups of the dashboard's inputs (PLAN §24 item 6).

  `compute/3` aggregates any interval of invocations with the same SQL expressions the
  exact panels use; the job stores one row per project and hour, and the dashboard reads
  a window as the stored full hours plus `compute/3` over the partial hours at both edges,
  so counts and sums are exact and only percentiles come from a digest. A scope with a
  free-form query keeps the exact path.
  """
  import Ecto.Query

  alias Conveyor.Invocations.{Invocation, Metrics}
  alias Conveyor.Metrics.{Digest, Scope}
  alias Conveyor.Repo

  defmodule Row do
    @moduledoc "One rolled-up hour of one project (or a combination of several)."
    use Ecto.Schema

    @primary_key false
    schema "invocation_rollups" do
      field :project_id, :integer, primary_key: true
      field :hour, :utc_datetime, primary_key: true
      field :builds, :integer, default: 0
      field :succeeded, :integer, default: 0
      field :failed, :integer, default: 0
      field :aborted, :integer, default: 0
      field :running, :integer, default: 0
      field :other, :integer, default: 0
      field :cache_hits_all, :integer
      field :executed_all, :integer
      field :cache_hits, :integer
      field :executed, :integer
      field :users, {:array, :string}, default: []
      field :durations, :map, default: %{}
      field :phases, :map, default: %{}
      field :queued_ms, :float
      field :profiled, :integer, default: 0
      field :mnemonic_counts, :map, default: %{}
      field :mnemonic_ms, :map, default: %{}
      field :updated_at, :utc_datetime_usec
    end
  end

  @type filter :: (Ecto.Query.t() -> Ecto.Query.t())

  @finished ["succeeded", "failed", "aborted"]

  @doc "Whether a scope can be served from rollups (no free-form query)."
  @spec applicable?(Scope.t()) :: boolean()
  def applicable?(%Scope{query: []}),
    do: Application.get_env(:conveyor, __MODULE__, [])[:enabled] != false

  def applicable?(_scope), do: false

  # --- computing -------------------------------------------------------------------------

  @doc "Aggregates the invocations that `filter` selects and started in `[from, to)`."
  @spec compute(filter(), DateTime.t(), DateTime.t()) :: Row.t()
  def compute(filter, from, to) do
    base =
      Invocation
      |> where([i], i.started_at >= ^from and i.started_at < ^to)
      |> filter.()

    finished = where(base, [i], i.status in @finished)

    counts =
      base
      |> group_by([i], i.status)
      |> select([i], {i.status, count(i.id)})
      |> Repo.all()
      |> Map.new()

    {hits_all, executed_all} =
      base |> select([i], {sum(i.remote_cache_hits), sum(i.actions_executed)}) |> Repo.one()

    {hits, executed, users, durations} =
      finished
      |> select([i], {
        sum(i.remote_cache_hits),
        sum(i.actions_executed),
        fragment("array_remove(array_agg(DISTINCT ?), NULL)", i.user_name),
        fragment("array_remove(array_agg(?), NULL)", i.duration_ms)
      })
      |> Repo.one()

    profiles =
      finished
      |> join(:inner, [i], m in Metrics, on: m.invocation_id == i.id)
      |> join(
        :inner,
        [i, m],
        p in fragment("jsonb_array_elements(? -> 'action_phases')", m.profile_summary),
        on: true
      )

    phases =
      profiles
      |> group_by([i, m, p], fragment("? ->> 'name'", p))
      |> select(
        [i, m, p],
        {fragment("? ->> 'name'", p), sum(fragment("(? ->> 'total_ms')::float", p))}
      )
      |> Repo.all()
      |> Map.new()

    {queued, profiled} =
      profiles
      |> select([i, m, p], {
        sum(fragment("(? ->> 'total_ms')::float", p))
        |> filter(fragment("? ->> 'name' = 'queued'", p)),
        count(i.id, :distinct)
      })
      |> Repo.one()

    with_metrics = join(finished, :inner, [i], m in Metrics, on: m.invocation_id == i.id)

    mnemonic_counts =
      with_metrics
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
      |> Map.new(fn {name, created, executed} -> {name, [num(created), num(executed)]} end)

    mnemonic_ms =
      with_metrics
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
      |> Map.new()

    succeeded = Map.get(counts, "succeeded", 0)
    failed = Map.get(counts, "failed", 0)

    %Row{
      hour: truncate(from, :hour),
      builds: counts |> Map.values() |> Enum.sum(),
      succeeded: succeeded,
      failed: failed,
      aborted: Map.get(counts, "aborted", 0),
      running: Map.get(counts, "in_progress", 0),
      other: Map.get(counts, "disconnected", 0) + Map.get(counts, "unknown", 0),
      cache_hits_all: num(hits_all),
      executed_all: num(executed_all),
      cache_hits: num(hits),
      executed: num(executed),
      users: users || [],
      durations: Digest.to_map(Digest.new(durations || [])),
      phases: phases,
      queued_ms: num(queued),
      profiled: profiled || 0,
      mnemonic_counts: mnemonic_counts,
      mnemonic_ms: mnemonic_ms
    }
  end

  @doc "Computes and stores the row of one project and hour."
  @spec roll!(integer(), DateTime.t()) :: Row.t()
  def roll!(project_id, hour) do
    hour = truncate(hour, :hour)

    row =
      compute(
        &where(&1, [i], i.project_id == ^project_id),
        hour,
        DateTime.add(hour, 3600, :second)
      )

    now = DateTime.utc_now()

    attrs =
      row
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.merge(%{project_id: project_id, hour: hour, updated_at: now})

    Repo.insert_all(Row, [attrs],
      on_conflict: {:replace_all_except, [:project_id, :hour]},
      conflict_target: [:project_id, :hour]
    )

    %{row | project_id: project_id, updated_at: now}
  end

  @doc """
  Rolls every (project, hour) with a build started since `since` whose row is missing or
  older than the build's last change. Returns the number of rows written.
  """
  @spec refresh!(DateTime.t()) :: non_neg_integer()
  def refresh!(since), do: repair!(& &1, since, nil)

  # Rolls the stale hours among the invocations `filter` selects in `[from, to)`; the read
  # path calls this so a window is exact even before the job has seen its hours.
  defp repair!(filter, from, to) do
    stale = stale_hours(filter, from, to)
    Enum.each(stale, fn {project_id, hour} -> roll!(project_id, to_utc(hour)) end)
    length(stale)
  end

  defp stale_hours(filter, from, to) do
    Invocation
    |> where([i], i.started_at >= ^from)
    |> then(&if(to, do: where(&1, [i], i.started_at < ^to), else: &1))
    |> filter.()
    |> join(:left, [i], r in Row,
      on:
        r.project_id == i.project_id and
          r.hour == fragment("date_trunc('hour', ?)", i.started_at)
    )
    |> group_by([i, r], [
      i.project_id,
      fragment("date_trunc('hour', ?)", i.started_at),
      r.updated_at
    ])
    |> having([i, r], is_nil(r.updated_at) or r.updated_at < max(i.updated_at))
    |> select([i, r], {i.project_id, fragment("date_trunc('hour', ?)", i.started_at)})
    |> Repo.all()
  end

  @doc "Deletes a project's rollup rows older than `before` (retention)."
  @spec prune!(integer(), DateTime.t()) :: non_neg_integer()
  def prune!(project_id, before) do
    {n, _} =
      Repo.delete_all(from(r in Row, where: r.project_id == ^project_id and r.hour < ^before))

    n
  end

  # --- reading ----------------------------------------------------------------------------

  @doc """
  Verifies the scope's window once (rolling stale or missing hours) and marks the scope,
  so the panels of one page load skip the check `rows/1` would otherwise repeat.
  """
  @spec ensure!(Scope.t()) :: Scope.t()
  def ensure!(%Scope{} = scope) do
    if applicable?(scope) do
      {first_full, last_full} = full_hours(scope)

      if DateTime.compare(first_full, last_full) == :lt,
        do: repair!(filter(scope), first_full, last_full)

      %{scope | rolled: true}
    else
      scope
    end
  end

  defp full_hours(%Scope{from: from, to: to}),
    do: {ceil_hour(from), DateTime.add(truncate(to, :hour), -3600, :second)}

  @doc """
  The rows covering a scope: stored full hours in the middle, exact computations for the
  partial hours at both edges (the last full hour is computed too: the job may not have
  rolled it yet). Hours in the middle whose row is missing or older than their builds are
  rolled first, so a window is exact whether or not the job has run. Each row carries the
  hour it belongs to.
  """
  @spec rows(Scope.t()) :: [Row.t()]
  def rows(%Scope{from: from, to: to} = scope) do
    filter = filter(scope)
    # the stored middle stops one hour before the end, that hour is computed exactly
    {first_full, last_full} = full_hours(scope)

    if DateTime.compare(first_full, last_full) == :gt do
      [compute(filter, from, to)]
    else
      head =
        if DateTime.compare(from, first_full) == :lt,
          do: [compute(filter, from, first_full)],
          else: []

      unless scope.rolled, do: repair!(filter, first_full, last_full)

      middle =
        Row
        |> where([r], r.hour >= ^first_full and r.hour < ^last_full)
        |> rollup_filter(scope)
        |> Repo.all()

      [compute(filter, last_full, to) | head] ++ middle
    end
  end

  @doc "Combines rows into one (sums, unions, merged digests)."
  @spec combine([Row.t()]) :: Row.t()
  def combine([]), do: %Row{}

  def combine(rows) do
    Enum.reduce(rows, fn r, acc ->
      %Row{
        hour: acc.hour,
        builds: acc.builds + r.builds,
        succeeded: acc.succeeded + r.succeeded,
        failed: acc.failed + r.failed,
        aborted: acc.aborted + r.aborted,
        running: acc.running + r.running,
        other: acc.other + r.other,
        cache_hits_all: nil_sum(acc.cache_hits_all, r.cache_hits_all),
        executed_all: nil_sum(acc.executed_all, r.executed_all),
        cache_hits: nil_sum(acc.cache_hits, r.cache_hits),
        executed: nil_sum(acc.executed, r.executed),
        users: Enum.uniq(acc.users ++ r.users),
        durations:
          Digest.to_map(
            Digest.merge(Digest.from_map(acc.durations), Digest.from_map(r.durations))
          ),
        phases: Map.merge(acc.phases, r.phases, fn _, a, b -> a + b end),
        queued_ms: nil_sum(acc.queued_ms, r.queued_ms),
        profiled: acc.profiled + r.profiled,
        mnemonic_counts:
          Map.merge(acc.mnemonic_counts, r.mnemonic_counts, fn _, [c1, e1], [c2, e2] ->
            [c1 + c2, e1 + e2]
          end),
        mnemonic_ms: Map.merge(acc.mnemonic_ms, r.mnemonic_ms, fn _, a, b -> a + b end)
      }
    end)
  end

  @doc "Duration quantile of a row, in milliseconds (rounded), or nil."
  @spec quantile(Row.t(), float()) :: integer() | nil
  def quantile(%Row{durations: d}, q) do
    case Digest.quantile(Digest.from_map(d), q) do
      nil -> nil
      v -> round(v)
    end
  end

  @doc "The bucket start (`:hour` or `:day`) a row belongs to."
  @spec bucket(Row.t(), :hour | :day) :: DateTime.t()
  def bucket(%Row{hour: hour}, unit), do: truncate(hour, unit)

  # --- helpers ------------------------------------------------------------------------------

  defp filter(%Scope{project_id: nil, project_ids: ids}),
    do: &Conveyor.Invocations.maybe_projects(&1, ids)

  defp filter(%Scope{project_id: id}), do: &where(&1, [i], i.project_id == ^id)

  defp rollup_filter(query, %Scope{project_id: id}) when is_integer(id),
    do: where(query, [r], r.project_id == ^id)

  defp rollup_filter(query, %Scope{project_ids: :all}), do: query
  defp rollup_filter(query, %Scope{project_ids: ids}), do: where(query, [r], r.project_id in ^ids)

  defp nil_sum(nil, b), do: b
  defp nil_sum(a, nil), do: a
  defp nil_sum(a, b), do: a + b

  defp num(nil), do: nil
  defp num(%Decimal{} = d), do: d |> Decimal.to_float() |> round()
  defp num(f) when is_float(f), do: f
  defp num(n), do: n

  @doc false
  def truncate(%DateTime{} = dt, :hour), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}

  def truncate(%DateTime{} = dt, :day),
    do: %{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp ceil_hour(dt) do
    floor = truncate(dt, :hour)
    if DateTime.compare(floor, dt) == :eq, do: floor, else: DateTime.add(floor, 3600, :second)
  end

  defp to_utc(%NaiveDateTime{} = n), do: DateTime.from_naive!(n, "Etc/UTC")
  defp to_utc(%DateTime{} = d), do: d
end
