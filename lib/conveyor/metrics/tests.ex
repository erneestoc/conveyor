defmodule Conveyor.Metrics.Tests do
  @moduledoc "Cross-build test health: flaky, slow and failing tests within a scope."
  import Ecto.Query

  alias Conveyor.Invocations.{Target, TestResult}
  alias Conveyor.Metrics.Scope
  alias Conveyor.Repo

  @doc """
  One row per test label: runs, passed/failed/flaky/timeout counts (per build, from the
  target's overall test status), p50 duration and the last build it ran in.
  Sorted worst first: flaky and failing tests, then the slowest.
  """
  @spec overview(Scope.t(), keyword()) :: [map()]
  def overview(scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    ids = scope |> Scope.base() |> select([i], i.id)

    statuses =
      Target
      |> where([t], t.invocation_id in subquery(ids) and not is_nil(t.test_status))
      |> group_by([t], t.label)
      |> select([t], %{
        label: t.label,
        runs: count(t.id),
        passed: fragment("count(*) FILTER (WHERE ? = 'PASSED')", t.test_status),
        failed:
          fragment(
            "count(*) FILTER (WHERE ? IN ('FAILED','INCOMPLETE','REMOTE_FAILURE','FAILED_TO_BUILD'))",
            t.test_status
          ),
        flaky: fragment("count(*) FILTER (WHERE ? = 'FLAKY')", t.test_status),
        timeout: fragment("count(*) FILTER (WHERE ? = 'TIMEOUT')", t.test_status),
        last_invocation_id: fragment("max(?::text)", t.invocation_id)
      })
      |> Repo.all()

    durations =
      TestResult
      |> where([r], r.invocation_id in subquery(ids) and not is_nil(r.duration_ms))
      |> group_by([r], r.label)
      |> select(
        [r],
        {r.label, fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.duration_ms),
         max(r.duration_ms)}
      )
      |> Repo.all()
      |> Map.new(fn {label, p50, max} -> {label, {to_ms(p50), max}} end)

    statuses
    |> Enum.map(fn row ->
      {p50, max} = Map.get(durations, row.label, {nil, nil})
      Map.merge(row, %{p50: p50, max: max, health: health(row)})
    end)
    |> Enum.sort_by(&{health_rank(&1.health), -(&1.p50 || 0), &1.label})
    |> Enum.take(limit)
  end

  defp health(%{flaky: f}) when f > 0, do: "flaky"
  defp health(%{failed: f, timeout: t}) when f + t > 0, do: "failing"
  defp health(_), do: "healthy"

  defp health_rank("flaky"), do: 0
  defp health_rank("failing"), do: 1
  defp health_rank(_), do: 2

  defp to_ms(nil), do: nil
  defp to_ms(%Decimal{} = d), do: d |> Decimal.to_float() |> round()
  defp to_ms(f) when is_float(f), do: round(f)
  defp to_ms(n), do: n
end
