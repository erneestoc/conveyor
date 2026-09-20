defmodule Conveyor.Metrics.GoldenTest do
  @moduledoc """
  Exact dashboard numbers for `Conveyor.GoldenData`, computed by hand:

  Current window durations (finished): 100, 200, 300, 400, 1000.
  - p50 = 300; p90 = 400 + 0.6 × 600 = 760; p99 = 400 + 0.96 × 600 = 976
  - success rate = 4 / 5; cache hit rate = (80 + 60 + 10 + 0 + 25) / 400 = 0.4375
  - CI segment: p50 = 400, success 2 / 3, cache 150 / 300; Local: p50 = 200, cache 25 / 100

  Previous window durations: 200, 200, 600, 800.
  - p50 = 400; p90 = 600 + 0.7 × 200 = 740; p99 = 600 + 0.97 × 200 = 794
  - success rate = 3 / 4; cache hit rate = 100 / 400 = 0.25

  Deltas: builds (6 − 4) / 4 = 0.5; success (0.8 − 0.75) / 0.75; p50 (300 − 400) / 400 = −0.25;
  p90 20 / 740; p99 182 / 794; cache (0.4375 − 0.25) / 0.25 = 0.75.
  """
  use Conveyor.DataCase, async: true

  alias Conveyor.Metrics.{Dashboard, Scope}
  alias Conveyor.Projects

  @now ~U[2026-09-18 12:00:00.000000Z]

  setup do
    {:ok, project} =
      Projects.create_project(%{
        slug: "golden-#{System.unique_integer([:positive])}",
        name: "Golden"
      })

    {:ok, other} =
      Projects.create_project(%{
        slug: "golden-other-#{System.unique_integer([:positive])}",
        name: "Other"
      })

    Conveyor.GoldenData.insert!(project.id, other.id, @now)
    %{scope: Scope.new("7d", project.id, [], @now)}
  end

  test "summary is exact", %{scope: scope} do
    assert Dashboard.summary(scope) == %{
             builds: 6,
             succeeded: 4,
             failed: 1,
             aborted: 0,
             running: 1,
             other: 0,
             success_rate: 0.8,
             p50: 300,
             p90: 760,
             p99: 976,
             cache_hit_rate: 0.4375,
             users: 2
           }
  end

  test "previous window and deltas are exact", %{scope: scope} do
    previous = Scope.previous(scope)
    assert previous.to == scope.from
    assert previous.from == ~U[2026-09-04 12:00:00.000000Z]

    p = Dashboard.summary(previous)

    assert %{builds: 4, succeeded: 3, failed: 1, success_rate: 0.75, p50: 400, p90: 740, p99: 794} =
             p

    assert p.cache_hit_rate == 0.25

    d = Dashboard.deltas(Dashboard.summary(scope), p)
    assert d.builds == 0.5
    assert d.p50 == -0.25
    assert d.cache_hit_rate == 0.75
    assert_in_delta d.success_rate, 0.05 / 0.75, 1.0e-12
    assert_in_delta d.p90, 20 / 740, 1.0e-12
    assert_in_delta d.p99, 182 / 794, 1.0e-12

    empty = Dashboard.summary(Scope.new("24h", -1, [], @now))

    assert Dashboard.deltas(empty, p) == %{
             builds: -1.0,
             success_rate: nil,
             p50: nil,
             p90: nil,
             p99: nil,
             cache_hit_rate: nil
           }

    assert Dashboard.deltas(p, empty).builds == nil
  end

  test "segments are exact", %{scope: scope} do
    [{"Local", local}, {"CI", ci}] =
      scope
      |> Scope.segments(Conveyor.Projects.Segments.defaults())
      |> Enum.map(&{&1.name, Dashboard.summary(&1)})

    assert %{builds: 3, succeeded: 2, failed: 1, p50: 400, cache_hit_rate: 0.5} = ci
    assert_in_delta ci.success_rate, 2 / 3, 1.0e-12

    assert %{
             builds: 3,
             succeeded: 2,
             running: 1,
             success_rate: 1.0,
             p50: 200,
             cache_hit_rate: 0.25
           } = local
  end

  test "series buckets sum to the window", %{scope: scope} do
    series = Dashboard.series(scope)
    assert length(series) == 8
    assert Enum.map(series, &(&1.succeeded + &1.failed + &1.other)) |> Enum.sum() == 6

    assert Enum.sum(
             Enum.map(Dashboard.series(Scope.previous(scope)), &(&1.succeeded + &1.failed))
           ) == 4

    assert [_ | _] = Enum.filter(series, &(&1.p50 == 1000 and &1.cache_hit_rate == 0.1))
  end
end
