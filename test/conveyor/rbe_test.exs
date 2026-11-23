defmodule Conveyor.RbeTest do
  @moduledoc """
  The duplicate-work analysis end to end: logs built from the recorded fixture with
  chosen times (`Conveyor.ExecLogBuilder`: 12 spawns, one a second, 500 ms each), stored
  through `ExecLog.store!/2`, read back through the rollup and the report. Golden numbers
  are exact.
  """
  use Conveyor.DataCase, async: false

  alias Conveyor.{ExecLog, ExecLogBuilder, Projects}
  alias Conveyor.ExecLog.{ActionKey, Cores, Keys, Spawn}
  alias Conveyor.Invocations.{Invocation, Metrics, Target}
  alias Conveyor.Metrics.{Rollup, Scope}
  alias Conveyor.Rbe.{Fleet, Groups, Report, Settings}

  @t0 ~U[2026-11-20 10:00:00.000000Z]

  setup do
    %{project: Projects.ensure_default_project!()}
  end

  defp at(ms), do: DateTime.add(@t0, ms, :millisecond)

  defp build!(project, offset_ms, attrs \\ %{}) do
    start = at(offset_ms)

    Repo.insert!(
      struct(
        %Invocation{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          status: "succeeded",
          tags: %{},
          inserted_at: start,
          updated_at: start,
          started_at: start,
          finished_at: DateTime.add(start, 20, :second)
        },
        attrs
      )
    )
  end

  # Stores a log whose spawn 0 starts when the build does.
  defp store!(inv, opts \\ []) do
    {:ok, parsed} =
      [id: inv.id, base: inv.started_at]
      |> Keyword.merge(opts)
      |> ExecLogBuilder.log()
      |> ExecLog.parse()

    ExecLog.store!(inv, parsed)
    parsed
  end

  defp scope(project_or_ids) do
    base = %Scope{from: at(-60_000), to: at(600_000)}

    case project_or_ids do
      %{id: id} -> %{base | project_id: id}
      ids when is_list(ids) -> %{base | project_ids: ids}
    end
  end

  defp report(project, opts \\ []) do
    project = Projects.get_project!(project.id)
    Report.build(scope(project), Keyword.put_new(opts, :settings, Settings.get(project)))
  end

  defp keys(scope), do: Repo.all(from k in ActionKey, where: k.scope == ^scope, order_by: k.key)

  describe "classification" do
    test "two shards racing: the later starter's executions are the racing duplicates", %{
      project: p
    } do
      a = build!(p, 0)
      b = build!(p, 200)
      store!(a)
      store!(b)

      r = report(p)
      assert r.coverage == %{builds: 2, logs: 2}
      assert r.executed == %{n: 24, ms: 12_000, core_ms: 12_000}
      assert r.racing.total == %{n: 12, ms: 6000, core_ms: 6000}
      assert r.racing.remotable == r.racing.total
      assert r.racing.time_share == 0.5
      assert r.cache.gap == %{n: 0, ms: 0, core_ms: 0}

      assert r.cache.hit_rate ==
               %{today: 0.0, perfect_cache: 0.0, with_in_flight_deduplication: 0.5}

      # the first release's names, kept as aliases
      assert r.cache.actual_rate == 0.0 and r.cache.ideal_rate == 0.0 and r.cache.rbe_rate == 0.5
      # Each started 300 ms before the first one finished: inside any tolerance.
      assert r.racing.uncertain.racing.n == 12 and r.racing.uncertain.sequential.n == 0
      assert r.keys == %{"fallback" => 24}

      assert [%{mnemonic: "TestRunner"} = tests, %{mnemonic: "Genrule"} = genrules] = r.mnemonics
      assert tests.executed == %{n: 20, ms: 10_000, core_ms: 10_000}
      assert tests.racing == %{n: 10, ms: 5000, core_ms: 5000}
      assert genrules.racing == %{n: 2, ms: 1000, core_ms: 1000}
      assert tests.cores == 1.0 and tests.cores_source == "default"

      assert %{target: "//app:sharded_test", racing: %{n: 6, ms: 3000}} = hd(r.targets)
      assert Enum.sum(Enum.map(r.targets, & &1.racing.ms)) == 6000

      # The first execution of every key is build a's.
      assert Enum.all?(keys(p.id), &(&1.first_invocation_id == a.id))
      assert length(keys(p.id)) == 12
    end

    test "three shards: two of the three executions of every action are wasted", %{project: p} do
      for offset <- [0, 200, 400], do: store!(build!(p, offset))

      r = report(p)
      assert r.executed.ms == 18_000
      assert r.racing.total == %{n: 24, ms: 12_000, core_ms: 12_000}
      assert r.cache.rbe_rate == 24 / 36
    end

    test "a later duplicate is what a shared cache saves; a cache hit is not an execution", %{
      project: p
    } do
      store!(build!(p, 0))
      store!(build!(p, 60_000))
      store!(build!(p, 120_000), each: fn s, _ -> ExecLogBuilder.hit(s) end)

      r = report(p)
      assert r.executed == %{n: 24, ms: 12_000, core_ms: 12_000}
      assert r.cache.hits == 12 and r.cache.spawns == 36
      assert r.cache.actual_rate == 12 / 36
      assert r.cache.ideal_rate == 24 / 36
      assert r.cache.gap == %{n: 12, ms: 6000, core_ms: 6000}
      assert r.cache.same_project == r.cache.gap
      assert r.cache.cross_project.n == 0
      assert r.cache.gap_time_share == 0.5
      assert r.racing.total.n == 0
      # 60 s after the first one finished: outside every tolerance.
      assert r.racing.uncertain.sequential.n == 0
      assert Enum.find(r.mnemonics, &(&1.mnemonic == "Genrule")).hits == 2
    end

    test "clock tolerance: executions near the first one's finish are reported as uncertain",
         %{project: p} do
      store!(build!(p, 0))
      # starts 1.5 s after each first execution finished
      store!(build!(p, 2000))

      assert report(p).racing.uncertain == %{
               tolerance_s: 2,
               racing: %{n: 0, ms: 0, core_ms: 0},
               sequential: %{n: 12, ms: 6000, core_ms: 6000}
             }

      {:ok, p} = Settings.put(p, %{"tolerance_s" => "1"})
      assert report(p).racing.uncertain.sequential.n == 0
    end

    test "failed, uncacheable and local executions are counted apart", %{project: p} do
      each = fn s, i ->
        case i do
          0 -> %{s | exit_code: 1, status: "NON_ZERO_EXIT"}
          1 -> %{s | cacheable: false}
          2 -> %{s | remote_cacheable: false}
          3 -> %{s | remotable: false}
          4 -> %{s | metrics: %{s.metrics | start_time: nil}}
          _ -> s
        end
      end

      store!(build!(p, 0), each: each)
      store!(build!(p, 200), each: each)

      r = report(p)
      assert r.not_dedupable.failed.n == 2
      assert r.not_dedupable.uncacheable.n == 4
      assert r.not_dedupable.unkeyed.n == 2
      assert r.not_dedupable.nonremote == %{n: 2, ms: 1000, core_ms: 1000}
      # 8 keyed actions raced; the one that may not run remotely is counted apart
      assert r.racing.total.n == 8 and r.racing.local.n == 1 and r.racing.remotable.n == 7
      assert length(keys(p.id)) == 8
      assert Repo.aggregate(from(s in Spawn, where: is_nil(s.action_key)), :count) == 8
    end
  end

  describe "arrival order" do
    test "any order of parsing gives the same rows and the same report", %{project: p} do
      builds = for offset <- [0, 200, 400, 60_000], do: build!(p, offset)
      logs = Map.new(builds, &{&1.id, ExecLogBuilder.log(id: &1.id, base: &1.started_at)})

      results =
        for order <- [builds, Enum.reverse(builds), Enum.shuffle(builds), Enum.shuffle(builds)] do
          Repo.delete_all(Spawn)
          Repo.delete_all(ActionKey)

          for inv <- order do
            {:ok, parsed} = ExecLog.parse(logs[inv.id])
            ExecLog.store!(inv, parsed)
          end

          {keys(p.id), report(p)}
        end

      assert [{rows, r} | rest] = results
      assert Enum.all?(rest, &(&1 == {rows, r}))
      assert Enum.all?(rows, &(&1.first_invocation_id == hd(builds).id))
      assert r.racing.total.n == 24 and r.cache.gap.n == 12
    end

    test "a log parsed later that finished earlier takes over, and the hours already rolled are rolled again",
         %{project: p} do
      now = DateTime.utc_now()
      old = %{DateTime.add(Rollup.truncate(now, :hour), -5, :hour) | microsecond: {0, 6}}
      late = %{inserted_at: old, updated_at: old, started_at: old}
      a = build!(p, 0, late)
      b = build!(p, 0, %{late | started_at: DateTime.add(old, 200, :millisecond)})
      scope = %Scope{project_id: p.id, from: DateTime.add(old, -3600), to: now}
      read = fn -> Report.build(scope, settings: Settings.get(p)) end

      # b's log arrives first: its executions are the first ones, the hour is rolled.
      store!(b)
      assert read.().racing.total.n == 0
      assert %Rollup.Row{} = Repo.get_by(Rollup.Row, project_id: p.id, hour: old)
      rolled_at = Repo.get!(Invocation, b.id).updated_at

      # a's log: every one of its executions finished before b's.
      store!(a)
      assert DateTime.compare(Repo.get!(Invocation, b.id).updated_at, rolled_at) == :gt
      assert Enum.all?(keys(p.id), &(&1.first_invocation_id == a.id))
      r = read.()
      assert r.racing.total == %{n: 12, ms: 6000, core_ms: 6000}
      assert r.executed.n == 24
    end

    test "parsing the same log again changes nothing; another log for the build replaces its part",
         %{project: p} do
      a = build!(p, 0)
      b = build!(p, 200)
      store!(a)
      store!(b)
      before = {keys(p.id), report(p)}

      store!(a)
      store!(b)
      assert {keys(p.id), report(p)} == before

      # a's log is uploaded again with every execution a minute later, and without its
      # first three spawns: b's executions are the first ones now.
      store!(a, base: at(60_000), each: fn s, i -> if i > 2, do: s end)
      rows = keys(p.id)
      assert length(rows) == 12
      assert Enum.all?(rows, &(&1.first_invocation_id == b.id))
      r = report(p)
      assert r.executed.n == 21 and r.racing.total.n == 0 and r.cache.gap.n == 9

      # with b's spawns gone, a's nine keys are a's again; the three only b had stay b's
      Repo.delete_all(from s in Spawn, where: s.invocation_id == ^b.id)
      store!(a, base: at(61_000), each: fn s, i -> if i > 2, do: s end)
      assert Enum.frequencies_by(keys(p.id), & &1.first_invocation_id) == %{a.id => 9, b.id => 3}

      # and a log without executions takes its keys away
      store!(a, each: fn s, _ -> ExecLogBuilder.hit(s) end)
      assert Enum.frequencies_by(keys(p.id), & &1.first_invocation_id) == %{b.id => 3}
    end

    test "two parsers at once: the rows are those of either order", %{project: p} do
      builds = for offset <- [0, 100, 200, 300], do: build!(p, offset)

      builds
      |> Enum.map(fn inv ->
        log = ExecLogBuilder.log(id: inv.id, base: inv.started_at)

        Task.async(fn ->
          {:ok, parsed} = ExecLog.parse(log)
          ExecLog.store!(inv, parsed)
        end)
      end)
      |> Task.await_many(30_000)

      assert Enum.all?(keys(p.id), &(&1.first_invocation_id == hd(builds).id))
      r = report(p)
      assert r.executed.n == 48 and r.racing.total.n == 36
      assert Repo.aggregate(Spawn, :count) == 48
    end
  end

  describe "the key" do
    test "Bazel's action digest when the log has it, the fallback otherwise", %{project: p} do
      with_digest = fn s, i -> ExecLogBuilder.digest(s, "action #{i}") end
      a = store!(build!(p, 0), each: with_digest)
      store!(build!(p, 200), each: with_digest)
      # no digest in the third log: the same actions under other keys, no duplicates found
      store!(build!(p, 400))

      assert hd(a.spawns).action_key == :crypto.hash(:sha256, "action 0")
      r = report(p)
      assert r.keys == %{"bazel" => 24, "fallback" => 12}
      assert r.racing.total.n == 12

      assert ActionKey.source_name(0) == "bazel" and ActionKey.source_name(nil) == "none"
      odd = %{digest: %{hash: "not hex"}}
      assert {<<_::binary-size(32)>>, 0} = ActionKey.of(odd, "", [])
    end

    test "the fallback key covers the command line, the environment, the platform and the inputs" do
      [spawn | _] = for %{type: {:spawn, s}} <- ExecLogBuilder.entries(), do: s
      key = fn s, inputs -> elem(ActionKey.of(s, inputs, ["out"]), 0) end
      base = key.(spawn, "inputs")

      assert key.(spawn, "inputs") == base
      assert key.(%{spawn | env_vars: Enum.reverse(spawn.env_vars)}, "inputs") == base
      assert key.(%{spawn | args: spawn.args ++ ["x"]}, "inputs") != base
      assert key.(%{spawn | env_vars: tl(spawn.env_vars)}, "inputs") != base
      assert key.(ExecLogBuilder.platform(spawn, %{"os" => "linux"}), "inputs") != base
      assert key.(spawn, "other inputs") != base
      assert elem(ActionKey.of(spawn, "inputs", ["other"]), 0) != base
    end

    test "one action slot under two keys at one commit is a near miss", %{project: p} do
      tags = %{tags: %{"commit" => "abc"}}
      a = build!(p, 0, tags)
      b = build!(p, 200, tags)
      store!(a)
      # one spawn of b sees another environment: another key for the same output
      store!(b, each: fn s, i -> if i == 5, do: %{s | args: s.args ++ ["--stamp"]}, else: s end)

      r = report(p)
      assert r.near.n == 1 and r.near.ms == 500
      assert [%{"invocation" => inv, "first" => first, "mnemonic" => _}] = r.near.examples
      assert inv == b.id and first == a.id
      assert r.racing.total.n == 11
    end

    test "one key with two sets of outputs is not deterministic", %{project: p} do
      # every spawn of both logs under one digest: twelve different outputs for one key
      same = fn s, _ -> ExecLogBuilder.digest(s, "one action") end
      store!(build!(p, 0), each: same)
      assert [%{nondet: true}] = keys(p.id)
      assert report(p).nondet.n == 12
    end
  end

  describe "cores" do
    test "exec property, target tag, measured, default, and the project's setting", %{project: p} do
      inv = build!(p, 0)

      Repo.insert!(%Target{invocation_id: inv.id, label: "//app:pass_test", cpus: 2})

      Repo.insert!(%Metrics{
        invocation_id: inv.id,
        build_metrics: %{
          "actionSummary" => %{
            "actionData" => [
              # 3 s of CPU over the two genrules' 1 s of wall time: 3 cores
              %{"mnemonic" => "Genrule", "userTime" => "2.5s", "systemTime" => "0.5s"},
              %{"mnemonic" => "Other", "userTime" => "soon"},
              %{"mnemonic" => "Untimed"}
            ]
          }
        }
      })

      parsed =
        store!(inv,
          each: fn s, _ ->
            if s.target_label == "//app:sharded_test",
              do: ExecLogBuilder.platform(s, %{"OSFamily" => "macos", "Cores" => "4"}),
              else: s
          end
        )

      by_target = fn label ->
        Repo.all(
          from s in Spawn,
            where: s.invocation_id == ^inv.id and s.target_label == ^label,
            select: {s.mnemonic, s.cores_milli, s.cores_source},
            distinct: true
        )
      end

      assert by_target.("//app:sharded_test") == [{"TestRunner", 4000, 3}]
      assert by_target.("//app:pass_test") == [{"TestRunner", 2000, 2}]
      assert by_target.("//lib:greeting") == [{"Genrule", 3000, 1}]
      assert by_target.("//app:uses_greeting_test") == [{"TestRunner", 1000, 0}]
      assert length(parsed.spawns) == 12

      r = report(p)
      tests = Enum.find(r.mnemonics, &(&1.mnemonic == "TestRunner"))
      # 6 sharded × 4 + 2 pass × 2 + 2 other × 1 cores, 500 ms each
      assert tests.executed == %{n: 10, ms: 5000, core_ms: 15_000}
      assert tests.cores == 3.0 and tests.cores_source == "exec property + target tag"
      genrules = Enum.find(r.mnemonics, &(&1.mnemonic == "Genrule"))
      assert genrules.executed.core_ms == 3000 and genrules.cores_source == "measured"

      # The project's own statement replaces every estimate, never the exec property.
      {:ok, p} = Settings.put(p, %{"cores" => "TestRunner=8\nGenrule = 0.5"})
      r = report(p)
      tests = Enum.find(r.mnemonics, &(&1.mnemonic == "TestRunner"))
      assert tests.executed.core_ms == 6 * 500 * 4 + 4 * 500 * 8
      assert tests.cores_source == "exec property + project setting"
      genrules = Enum.find(r.mnemonics, &(&1.mnemonic == "Genrule"))
      assert genrules.executed.core_ms == 500 and genrules.cores_source == "project setting"
      assert r.executed.core_ms == 28_000 + 500
    end

    test "a mnemonic whose every action states its cores", %{project: p} do
      store!(build!(p, 0), each: fn s, _ -> ExecLogBuilder.platform(s, %{"cpu" => "2000m"}) end)
      r = report(p)
      assert Enum.all?(r.mnemonics, &(&1.cores == 2.0 and &1.cores_source == "exec property"))
    end

    test "reading cores from tags and platform properties" do
      assert Cores.from_tags(["manual", "cpu:4"]) == 4
      assert Cores.from_tags(["resources:cpu:8"]) == 8
      assert Cores.from_tags(["cpu:0", "cpu:x", "requires-network"]) == nil
      assert Cores.from_platform(nil) == nil
      property = fn k, v -> %{properties: [%{name: k, value: v}]} end
      assert Cores.from_platform(property.("EstimatedCPU", "2.5")) == 2500
      assert Cores.from_platform(property.("cores", "many")) == nil
      assert Cores.from_platform(property.("Pool", "4")) == nil
      assert Cores.source_name(3) == "exec property" and Cores.source_name(2) == "target tag"
      assert Cores.source_name(1) == "measured" and Cores.source_name(nil) == "default"
    end
  end

  describe "cache groups" do
    setup %{project: p} do
      {:ok, other} = Projects.create_project(%{slug: "other-app", name: "Other app"})
      {:ok, p} = Groups.put(p, "monorepo")
      {:ok, other} = Groups.put(other, "monorepo")
      %{project: p, other: other, group: Groups.of(p)}
    end

    test "a duplicate of another project's finished work is the cross-project gap", %{
      project: p,
      other: other,
      group: group
    } do
      assert Groups.scopes(p) == [{p.id, [p.id]}, {-group.id, [p.id, other.id]}]
      assert Enum.map(Groups.members(group), & &1.id) == [p.id, other.id]

      a = build!(p, 0)
      store!(a)
      # the other app redoes it a minute later, twice
      store!(build!(other, 60_000))
      store!(build!(other, 120_000))

      assert length(keys(p.id)) == 12 and length(keys(other.id)) == 12
      rows = keys(-group.id)
      assert length(rows) == 12
      assert Enum.all?(rows, &(&1.multi and &1.first_invocation_id == a.id))

      names = %{p.id => p.name, other.id => other.name}
      mine = report(p, names: names)
      assert mine.executed.n == 12 and mine.cache.gap.n == 0 and mine.racing.total.n == 0
      assert [%{name: "Default", shared_share: 1.0, from: []}] = mine.projects.rows

      # the first of them redid only the other project's work, the second also its own
      theirs = report(other, names: names)
      assert theirs.executed.n == 24 and theirs.racing.total.n == 0
      assert theirs.cache.cross_project == %{n: 12, ms: 6000, core_ms: 6000}
      assert theirs.cache.same_project == %{n: 12, ms: 6000, core_ms: 6000}
      assert theirs.cache.gap.n == 24

      # a third build of the other app, parsed last, raced the first project: it is its
      # own project's first, and both later builds now redo their own project's work
      store!(build!(other, 200))
      theirs = report(other, names: names)
      assert theirs.executed.n == 36
      assert theirs.racing.total.n == 12 and theirs.racing.cross_project.n == 12
      assert theirs.cache.cross_project.n == 0 and theirs.cache.same_project.n == 24

      assert [%{name: "Other app", from: [%{name: "Default", cell: %{n: 36}}]}] =
               theirs.projects.rows

      # the group: both projects, and to a viewer of only one, the other without its name
      whole = Report.build(scope([p.id, other.id]), settings: Settings.get(p), names: names)
      assert whole.executed.n == 48
      assert Enum.map(whole.projects.rows, & &1.name) == ["Other app", "Default"]
      assert whole.projects.others == nil

      partial =
        Report.build(scope([p.id, other.id]),
          settings: Settings.get(p),
          names: names,
          visible: [other.id]
        )

      assert partial.executed.n == 48

      assert [%{name: "Other app", from: [%{id: nil, name: "other projects"}]}] =
               partial.projects.rows

      assert %{count: 1, executed: %{n: 12}} = partial.projects.others
      assert Enum.all?(partial.targets, &(&1.project == "Other app"))
      refute inspect(Report.to_json(partial)) =~ "Default"
    end

    test "group names, leaving a group, live scopes", %{project: p, other: other, group: group} do
      assert {:error, _} = Groups.put(p, "Not A Name")
      assert Groups.get_by_name("monorepo").id == group.id
      assert -group.id in Groups.live_scopes() and other.id in Groups.live_scopes()
      {:ok, p} = Groups.put(p, " ")
      assert Groups.of(p) == nil and Groups.name(p) == nil
      assert Groups.scopes(p) == [{p.id, [p.id]}]
      assert Groups.members(nil) == []
    end
  end

  describe "per logged day" do
    defp week(project),
      do: %Scope{from: at(-6 * 86_400_000 - 3_600_000), to: at(3_600_000), project_id: project.id}

    defp week_report(project),
      do: Report.build(week(project), settings: Settings.get(Projects.get_project!(project.id)))

    test "logs on one day of seven: the divisor is 1, the window's total stays", %{project: p} do
      # builds on every day, logs on the last one only
      for d <- 1..6, do: build!(p, -d * 86_400_000)
      store!(build!(p, 0))
      store!(build!(p, 200))

      r = week_report(p)
      assert r.coverage == %{builds: 8, logs: 2}
      assert r.logged_days == 1 and r.window_days == 7
      assert r.racing.remotable == %{n: 12, ms: 6000, core_ms: 6000}
      assert r.per_logged_day.racing == %{n: 12.0, ms: 6000, core_ms: 6000}
      assert r.per_logged_day.sequential == %{n: 0.0, ms: 0, core_ms: 0}
      assert Report.to_json(r)["logged_days"] == 1
    end

    test "logs on two UTC days: the total over two; a day is the UTC day of the build's start",
         %{project: p} do
      store!(build!(p, 0))
      store!(build!(p, 200))
      # 23:59:50 two days earlier: its log's spawns run past midnight, the day is the start's
      late = -2 * 86_400_000 + 14 * 3_600_000 - 10_000
      store!(build!(p, late))
      store!(build!(p, late + 200))

      r = week_report(p)
      assert r.logged_days == 2
      # the earlier pair raced; today's 24 executions repeat finished results
      assert r.racing.remotable.core_ms == 6000 and r.cache.gap.core_ms == 12_000
      assert r.per_logged_day.racing.core_ms == 3000
      assert r.per_logged_day.sequential == %{n: 12.0, ms: 6000, core_ms: 6000}
    end

    test "logs on no day: no per-day figure", %{project: p} do
      for d <- 0..6, do: build!(p, -d * 86_400_000)
      r = week_report(p)
      assert r.coverage == %{builds: 7, logs: 0}
      assert r.logged_days == 0 and r.window_days == 7
      assert r.per_logged_day == %{sequential: nil, racing: nil, cold: nil}
      assert Report.to_json(r)["per_logged_day"]["racing"] == nil
    end
  end

  describe "pipelines, retention, settings" do
    test "racing per pipeline leaves out what may not run remotely, like the headline", %{
      project: p
    } do
      {:ok, p} = Settings.put(p, %{"pipeline_key" => "pipeline"})
      each = fn s, i -> if i == 3, do: %{s | remotable: false}, else: s end
      store!(build!(p, 0, %{tags: %{"pipeline" => "run-1"}}), each: each)
      store!(build!(p, 200, %{tags: %{"pipeline" => "run-1"}}), each: each)

      r = report(p)
      assert r.racing.local.n == 1 and r.racing.remotable.n == 11
      assert [%{value: "run-1", n: 11, ms: 5500}] = r.pipelines
    end

    test "racing time per value of the pipeline tag", %{project: p} do
      {:ok, p} = Settings.put(p, %{"pipeline_key" => "pipeline", "tolerance_s" => "5"})

      assert Settings.get(p) == %{
               cores: %{},
               pipeline_key: "pipeline",
               tolerance_s: 5,
               cores_property: Cores.default_property()
             }

      store!(build!(p, 0, %{tags: %{"pipeline" => "run-1"}}))
      store!(build!(p, 200, %{tags: %{"pipeline" => "run-1"}}))
      store!(build!(p, 400, %{tags: %{"pipeline" => "run-2"}}))

      assert [%{value: "run-1", n: 12, ms: 6000}, %{value: "run-2", n: 12}] = report(p).pipelines
    end

    test "settings are validated", %{project: p} do
      assert {:error, "cores" <> _} = Settings.put(p, %{"cores" => "TestRunner"})
      assert {:error, "cores" <> _} = Settings.put(p, %{"cores" => "TestRunner=0"})
      assert {:error, "the pipeline key" <> _} = Settings.put(p, %{"pipeline_key" => "Not A Key"})
      assert {:error, "the tolerance" <> _} = Settings.put(p, %{"tolerance_s" => "3"})
      {:ok, p} = Settings.put(p, %{"cores" => "B=2, A=1.5", "tolerance_s" => ""})
      settings = Settings.get(p)
      assert settings.cores == %{"A" => 1.5, "B" => 2.0} and settings.pipeline_key == nil
      assert Settings.cores_text(settings) == "A=1.5\nB=2"
      assert Settings.tolerances() == [1, 2, 5, 10, 30, 60]
    end

    test "keys are forgotten once their last execution is older than the retention", %{project: p} do
      day = 86_400_000
      store!(build!(p, 0))
      store!(build!(p, 2 * day), each: fn s, i -> if i < 6, do: s end)
      assert Keys.prune!(p.id, at(day)) == 6
      assert length(keys(p.id)) == 6
      # rows of a scope that no longer exists
      Repo.update_all(ActionKey, set: [scope: -999])
      assert Keys.prune_orphans!(Groups.live_scopes(), at(day)) == 0
      assert Keys.prune_orphans!(Groups.live_scopes(), at(3 * day)) == 6
      assert Keys.holders([p.id], [], "x") == []
    end

    test "the retention job prunes keys of projects, groups and scopes that are gone", %{
      project: p
    } do
      {:ok, p} = Groups.put(p, "retained")
      group = Groups.of(p)
      long_ago = DateTime.add(DateTime.utc_now(), -40, :day)
      old = build!(p, 0, %{started_at: long_ago, inserted_at: long_ago})
      store!(old)

      store!(build!(p, 0, %{started_at: DateTime.utc_now(), inserted_at: DateTime.utc_now()}),
        each: fn s, i -> if i < 4, do: s end
      )

      Repo.insert_all(ActionKey, [
        Map.merge(
          Map.take(hd(keys(p.id)), [
            :key,
            :first_finish,
            :first_start,
            :first_invocation_id,
            :first_ordinal,
            :last_finish
          ]),
          %{scope: -999_999, last_finish: long_ago}
        )
      ])

      Repo.insert!(%Groups{name: "empty", inserted_at: DateTime.utc_now()})

      assert {:ok, %{pruned_keys: 17}} =
               Oban.Testing.perform_job(Conveyor.Workers.BuildRetention, %{}, repo: Repo)

      assert length(keys(p.id)) == 4 and length(keys(-group.id)) == 4
    end
  end

  describe "the event-stream bound" do
    defp metrics!(inv, runners, action_data) do
      Repo.insert!(%Metrics{
        invocation_id: inv.id,
        build_metrics: %{
          "actionSummary" => %{
            "runnerCount" =>
              Enum.map(runners, fn {name, n} -> %{"name" => name, "count" => n} end),
            "actionData" => action_data
          }
        }
      })
    end

    test "executed work by runner and mnemonic, executed share, cold hosts", %{project: p} do
      go = fn executed, cpu ->
        [
          %{
            "mnemonic" => "GoCompilePkg",
            "actionsExecuted" => "#{executed}",
            "actionsCreated" => "100",
            "userTime" => "#{cpu}s",
            "systemTime" => "0s"
          }
        ]
      end

      # host-1: a cold first build, then three warm ones; host-2: one build; one without host
      for {offset, executed, hits} <- [
            {0, 90, 10},
            {60_000, 10, 90},
            {120_000, 10, 90},
            {180_000, 10, 90}
          ] do
        inv = build!(p, offset, %{host: "host-1"})

        metrics!(
          inv,
          [
            {"total", executed + hits + 5},
            {"internal", 5},
            {"linux-sandbox", executed},
            {"remote cache hit", hits}
          ],
          go.(executed, executed)
        )
      end

      inv = build!(p, 30_000, %{host: "host-2"})
      metrics!(inv, [{"total", 100}, {"linux-sandbox", 80}, {"disk cache hit", 20}], go.(80, 80))

      metrics!(build!(p, 240_000), [{"worker", 1}], [
        %{"mnemonic" => "GoLink", "actionsExecuted" => 1}
      ])

      build!(p, 300_000, %{host: "host-3"})

      fleet = report(p).fleet
      assert fleet.builds == 7 and fleet.with_metrics == 6
      assert fleet.hits == 300 and fleet.executed == 201
      assert fleet.executed_share == 201 / 501
      assert %{name: "remote cache hit", count: 280} = hd(fleet.runners)

      assert Enum.sum(fleet.share) == 6 and Enum.at(fleet.share, 9) == 2 and
               Enum.at(fleet.share, 1) == 3

      assert [
               %{
                 mnemonic: "GoCompilePkg",
                 executed: 200,
                 created: 500,
                 cpu_ms: 200_000,
                 timed: 200
               },
               %{mnemonic: "GoLink", cpu_ms: 0, timed: 0}
             ] =
               fleet.mnemonics

      assert fleet.cpu_ms == 200_000
      assert [first, second, third] = fleet.hosts.cold
      # the first build of host-1 and of host-2
      assert first == %{ordinal: 1, builds: 2, executed: 170, hits: 30, cpu_ms: 170_000}
      assert second.builds == 1 and third.builds == 1
      assert fleet.hosts.later == %{builds: 1, executed: 10, hits: 90, cpu_ms: 10_000}
      assert fleet.hosts.unknown.builds == 1
      # four cold builds executed 190 where four warm ones would have executed 40
      assert fleet.hosts.excess == %{builds: 4, executed: 150, cpu_ms: 150_000}

      # reading the window again writes no host row: nothing about them changed
      versions = fn ->
        Repo.query!("SELECT host, xmin::text FROM build_hosts ORDER BY host").rows
      end

      before = versions.()
      report(p)
      assert versions.() == before

      assert Fleet.prune!(p.id, at(10_000)) == 1
    end

    test "sequential duplicates in a host's first builds are the measured cold cost", %{
      project: p
    } do
      for offset <- [0, 60_000, 120_000, 180_000],
          do: store!(build!(p, offset, %{host: "host-1"}))

      store!(build!(p, 30_000, %{host: "host-2"}))

      r = report(p)
      assert r.cache.gap.n == 48
      # host-1's second and third build and host-2's first; host-1's fourth is warm
      assert r.cache.cold == %{n: 36, ms: 18_000, core_ms: 18_000}
    end

    test "without any log the report is the bound alone", %{project: p} do
      build!(p, 0)
      r = report(p)
      assert r.coverage == %{builds: 1, logs: 0}
      assert r.executed.n == 0 and r.cache.actual_rate == nil and r.parallelism == nil
      assert r.mnemonics == [] and r.projects == %{rows: [], others: nil}
      assert is_map(Report.to_json(r))
    end
  end

  test "parallelism: action time against the critical path and the execution phase", %{project: p} do
    store!(build!(p, 0, %{critical_path_ms: 2000, execution_ms: 3000}))
    assert report(p).parallelism == %{builds: 1, action_ms: 6000, achieved: 2.0, bound: 3.0}
    store!(build!(p, 60_000, %{execution_ms: 3000}))
    assert %{builds: 2, achieved: 2.0, bound: nil} = report(p).parallelism
  end
end
