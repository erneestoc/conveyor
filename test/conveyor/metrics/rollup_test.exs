defmodule Conveyor.Metrics.RollupTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.Metrics.{Dashboard, Rollup, Scope}
  alias Conveyor.Projects

  @now ~U[2026-09-18 12:00:00.000000Z]

  setup do
    {:ok, project} =
      Projects.create_project(%{slug: "roll-#{System.unique_integer([:positive])}", name: "R"})

    {:ok, other} =
      Projects.create_project(%{slug: "roll-o-#{System.unique_integer([:positive])}", name: "O"})

    Conveyor.GoldenData.insert!(project.id, other.id, @now)
    %{project: project, other: other}
  end

  test "rolled panels equal the exact panels for every scope shape", %{project: project} do
    since = DateTime.add(@now, -30, :day)
    # Reads heal themselves: a window read before the job ran is already exact.
    unrolled = Scope.new("30d", nil, [], @now)
    assert Dashboard.summary(unrolled) == Dashboard.exact_summary(unrolled)
    assert Repo.aggregate(Rollup.Row, :count) > 0
    # the read rolled every hour: the job finds nothing stale
    assert Rollup.refresh!(since) == 0

    for scope <- [
          Scope.new("7d", project.id, [], @now),
          Scope.new("7d", nil, [], @now),
          Scope.new("30d", nil, [], @now) |> Scope.restrict([project.id]),
          Scope.new("24h", project.id, [], @now),
          Scope.previous(Scope.new("7d", project.id, [], @now))
        ] do
      assert Rollup.applicable?(scope)
      assert Dashboard.summary(scope) == Dashboard.exact_summary(scope)
      assert Dashboard.series(scope) == Dashboard.exact_series(scope)
      assert Dashboard.phases_over_time(scope) == Dashboard.exact_phases_over_time(scope)
      assert Dashboard.queue_trend(scope) == Dashboard.exact_queue_trend(scope)

      assert Dashboard.actions_by_mnemonic(scope, 10) ==
               Dashboard.exact_actions_by_mnemonic(scope, 10)

      assert Dashboard.cache_by_mnemonic(scope, 10) ==
               Dashboard.exact_cache_by_mnemonic(scope, 10)

      assert Dashboard.top_cache_missing_targets(scope, 10) ==
               Dashboard.exact_top_cache_missing_targets(scope, 10)

      assert Dashboard.remote_bytes(scope) == Dashboard.exact_remote_bytes(scope)

      # A page verifies its window once and every panel reuses the rows.
      ensured = Rollup.ensure!(scope)
      assert is_list(ensured.rollup_rows)
      assert Dashboard.summary(ensured) == Dashboard.summary(scope)
      # derived windows never inherit the cached rows
      assert Scope.previous(ensured).rollup_rows == nil

      assert Dashboard.summary(Scope.previous(ensured)) ==
               Dashboard.exact_summary(Scope.previous(scope))
    end

    # A free-form query keeps the exact path.
    queried = Scope.new("7d", project.id, Conveyor.Query.parse!("status:failed"), @now)
    refute Rollup.applicable?(queried)
    assert Dashboard.summary(queried).failed == Dashboard.summary(queried).builds

    # Rows: exact edges around stored hours, all tagged with their hour.
    scope = Scope.new("7d", project.id, [], @now)
    rows = Rollup.rows(scope)
    assert Enum.all?(rows, &(&1.hour.minute == 0))
    assert Rollup.combine(rows).builds == Dashboard.exact_summary(scope).builds
    assert Rollup.combine([]).builds == 0

    # A window inside one hour is computed exactly, without stored rows.
    tiny = %{scope | from: DateTime.add(@now, -600, :second), to: @now}
    assert [_one] = Rollup.rows(tiny)
    assert Dashboard.summary(tiny) == Dashboard.exact_summary(tiny)
  end

  test "a changed build makes its hour stale again; retention prunes rows", %{project: project} do
    since = DateTime.add(@now, -30, :day)
    Rollup.refresh!(since)

    inv =
      Repo.one!(
        from(i in Conveyor.Invocations.Invocation, where: i.project_id == ^project.id, limit: 1)
      )

    Repo.update_all(from(i in Conveyor.Invocations.Invocation, where: i.id == ^inv.id),
      set: [status: "failed", updated_at: DateTime.utc_now()]
    )

    assert Rollup.refresh!(since) == 1

    assert Rollup.prune!(project.id, DateTime.add(@now, 1, :day)) > 0
    assert Rollup.prune!(project.id, DateTime.add(@now, 1, :day)) == 0

    # The worker rolls the recent window.
    assert {:ok, n} = perform_job(Conveyor.Workers.Rollup, %{"days" => 30})
    assert n > 0
  end

  test "a row is stamped from before its builds were read (docs/spec/Rollup.tla)", %{
    project: project
  } do
    before = DateTime.utc_now()
    row = Rollup.roll!(project.id, DateTime.add(@now, -3600, :second))
    # a change committed during the compute (or up to 5 s before it, clock skew) is newer
    assert DateTime.compare(row.updated_at, DateTime.add(before, -4, :second)) == :lt
  end

  test "rollups can be switched off" do
    Application.put_env(:conveyor, Rollup, enabled: false)
    on_exit(fn -> Application.put_env(:conveyor, Rollup, enabled: true) end)
    refute Rollup.applicable?(Scope.new("7d", nil))
  end
end
