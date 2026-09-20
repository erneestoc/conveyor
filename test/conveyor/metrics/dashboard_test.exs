defmodule Conveyor.Metrics.DashboardTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Metrics.{Dashboard, Scope, Tests}
  alias Conveyor.Projects

  setup do
    project = Projects.ensure_default_project!()

    {:ok, other} =
      Projects.create_project(%{
        slug: "other-#{System.unique_integer([:positive])}",
        name: "Other"
      })

    {200, _} = Mix.Tasks.Conveyor.Seed.seed(project.id, 200, 10, {1, 2, 3})
    {20, _} = Mix.Tasks.Conveyor.Seed.seed(other.id, 20, 10, {4, 5, 6})
    %{project: project, other: other}
  end

  test "scope construction" do
    now = ~U[2026-09-18 12:00:00.000000Z]
    scope = Scope.new("24h", 1, [], now)
    assert scope.from == ~U[2026-09-17 12:00:00.000000Z] and Scope.bucket(scope) == :hour
    assert Scope.bucket(Scope.new("7d", nil, [], now)) == :day
    assert Scope.new("bogus", nil, [], now).from == Scope.new("7d", nil, [], now).from

    assert [%{name: "Local", query: [%{key: "ci"}]}, %{name: "CI"}] =
             Scope.segments(scope, Conveyor.Projects.Segments.defaults())

    assert Scope.ranges() == ["24h", "7d", "30d", "90d"]
  end

  test "summary, segments and series are consistent", %{project: project} do
    scope = Scope.new("30d", project.id)
    s = Dashboard.summary(scope)
    assert s.builds == 200
    assert s.succeeded + s.failed + s.aborted + s.running + s.other == 200
    assert s.success_rate > 0 and s.success_rate <= 1
    assert s.p50 <= s.p90 and s.p90 <= s.p99
    assert s.cache_hit_rate > 0 and s.cache_hit_rate < 1
    assert s.users > 1

    [{"Local", local}, {"CI", ci}] =
      scope
      |> Scope.segments(Conveyor.Projects.Segments.defaults())
      |> Enum.map(&{&1.name, Dashboard.summary(&1)})

    assert local.builds + ci.builds == 200

    series = Dashboard.series(scope)
    assert length(series) in 30..31
    assert Enum.sum(Enum.map(series, &(&1.succeeded + &1.failed + &1.other))) == 200
    assert Enum.any?(series, &(&1.p50 != nil and &1.cache_hit_rate != nil))
    assert Enum.all?(series, &(&1.p50 == nil or &1.p50 <= &1.p99))

    hourly = Dashboard.series(Scope.new("24h", project.id))
    assert length(hourly) in 24..25

    assert Dashboard.summary(Scope.new("30d", -1)).builds == 0
    assert Dashboard.summary(Scope.new("30d", -1)).p50 == nil
    assert Dashboard.summary(Scope.new("30d", nil)).builds == 220
  end

  test "breakdowns", %{project: project} do
    scope = Scope.new("30d", project.id)
    failures = Dashboard.failure_breakdown(scope)
    assert Enum.all?(failures, fn {name, n} -> is_binary(name) and n > 0 end)
    assert failures == Enum.sort_by(failures, &elem(&1, 1), :desc)

    mix = Dashboard.strategy_mix(scope)
    assert {"remote cache hit", _} = List.keyfind(mix, "remote cache hit", 0)
    assert Dashboard.strategy_mix(Scope.new("30d", -1)) == []

    users = Dashboard.by_user(scope, 3)
    assert length(users) == 3 and hd(users).builds >= List.last(users).builds

    slowest = Dashboard.slowest_builds(scope, 5)
    assert length(slowest) == 5 and hd(slowest).duration_ms >= List.last(slowest).duration_ms

    assert [{_, _} | _] = Dashboard.versions(scope)
    targets = Dashboard.top_failing_targets(scope, 3)
    assert Enum.all?(targets, &(&1.failures > 0 and is_binary(&1.last_invocation_id)))
    assert Enum.sum(Enum.map(Dashboard.starts_heatmap(scope), &elem(&1, 2))) == 200
  end

  test "queries narrow the scope", %{project: project} do
    all = Dashboard.summary(Scope.new("30d", project.id))
    ci = Dashboard.summary(Scope.new("30d", project.id, Conveyor.Query.parse!("ci:true")))
    local = Dashboard.summary(Scope.new("30d", project.id, Conveyor.Query.parse!("ci:false")))
    assert ci.builds + local.builds == all.builds and ci.builds > 0 and local.builds > 0
  end

  test "test health overview", %{project: project} do
    scope = Scope.new("30d", project.id)
    rows = Tests.overview(scope)
    assert rows != []
    assert Enum.all?(rows, &(&1.health in ["failing", "flaky", "healthy"] and &1.runs > 0))
    assert Enum.all?(rows, &(&1.failed + &1.timeout > 0 or &1.health != "failing"))
    assert Tests.overview(Scope.new("30d", -1)) == []
    assert length(Tests.overview(scope, limit: 1)) == 1
  end
end
