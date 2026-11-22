defmodule Conveyor.RbeCoresTest do
  @moduledoc """
  How a project declares cores per action (PLAN §27.7): the setting, the parse with it,
  the property names seen in logs, the coverage figure and reading stored logs again.
  """
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.{Artifacts, Blobs, ExecLog, ExecLogBuilder, Projects}
  alias Conveyor.ExecLog.{Cores, Properties, Spawn}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.Scope
  alias Conveyor.Rbe.{Report, Reread, Settings}
  alias Conveyor.Workers.ParseExecLog

  @t0 ~U[2026-11-20 10:00:00.000000Z]
  @builtin ~w(cpu cpus cores num-cpus num_cpus EstimatedCPU resources:cpu)

  setup do
    %{project: Projects.ensure_default_project!()}
  end

  defp build!(project, offset_ms, attrs \\ %{}) do
    start = DateTime.add(@t0, offset_ms, :millisecond)

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

  defp log(inv, properties) do
    ExecLogBuilder.log(
      id: inv.id,
      base: inv.started_at,
      each: fn s, i -> ExecLogBuilder.platform(s, properties.(i)) end
    )
  end

  defp report(project) do
    project = Projects.get_project!(project.id)

    Report.build(
      %Scope{
        project_id: project.id,
        from: DateTime.add(@t0, -60, :second),
        to: DateTime.add(@t0, 600, :second)
      },
      settings: Settings.get(project)
    )
  end

  defp platform(properties),
    do: %{properties: Enum.map(properties, fn {k, v} -> %{name: k, value: v} end)}

  describe "the setting" do
    test "defaults to the built-in names with unit auto, and is not stored then", %{project: p} do
      assert Settings.get(p).cores_property == %{names: @builtin, unit: "auto"}
      assert Cores.default_property() == %{names: @builtin, unit: "auto"}
      assert Settings.units() == ~w(auto cores millicores)

      {:ok, p} = Settings.put(p, %{"cores_properties" => "  ", "cores_unit" => "auto"})
      refute Map.has_key?(p.settings["rbe"], "cores_property")
      assert Settings.names_text(Settings.get(p)) == Enum.join(@builtin, ", ")
    end

    test "names in order, by comma or line; a unit; kept when a later save leaves them out",
         %{project: p} do
      {:ok, p} =
        Settings.put(p, %{
          "cores_properties" => "Cores-Wanted, pool/cpu\nres:cpu",
          "cores_unit" => "millicores"
        })

      assert Settings.get(p).cores_property ==
               %{names: ["Cores-Wanted", "pool/cpu", "res:cpu"], unit: "millicores"}

      {:ok, p} = Settings.put(p, %{"cores" => "TestRunner=2"})
      assert Settings.get(p).cores_property.names == ["Cores-Wanted", "pool/cpu", "res:cpu"]
      assert Settings.get(p).cores_property.unit == "millicores"

      {:ok, p} = Settings.put(p, %{"cores_properties" => ""})
      assert Settings.get(p).cores_property == %{names: @builtin, unit: "millicores"}
    end

    test "rejects empty names, odd characters, long names, too many, repeats, an unknown unit",
         %{project: p} do
      for bad <- [
            "cores,,cpu",
            "cores,",
            "has space",
            "semi;colon",
            String.duplicate("a", 65),
            Enum.map_join(1..9, ",", &"n#{&1}"),
            "cores, CORES"
          ] do
        assert {:error, message} = Settings.put(p, %{"cores_properties" => bad}), bad
        assert message =~ "exec property name"
      end

      assert {:error, "the unit is one of" <> _} = Settings.put(p, %{"cores_unit" => "threads"})
      assert {:error, _} = Settings.put(p, %{"cores_properties" => ["cores"]})

      assert {:ok, _} =
               Settings.put(p, %{"cores_properties" => Enum.map_join(1..8, ",", &"n#{&1}")})

      assert Settings.get(Projects.get_project!(p.id)).cores_property.unit == "auto"
    end

    test "a stored value that is not a declaration reads as the default", %{project: p} do
      {:ok, p} =
        Projects.update_project(p, %{
          settings:
            Map.put(p.settings, "rbe", %{"cores_property" => %{"names" => [], "unit" => "x"}})
        })

      assert Settings.get(p).cores_property == Cores.default_property()
    end
  end

  describe "reading a platform" do
    test "a custom name under each unit" do
      one = fn value, unit ->
        Cores.from_platform(platform([{"Wanted", value}]), %{names: ["wanted"], unit: unit})
      end

      assert one.("4", "auto") == 4000
      assert one.("4000m", "auto") == 4000
      assert one.("0.5", "cores") == 500
      assert one.("250m", "cores") == 250
      assert one.("4000", "millicores") == 4000
      assert one.("4000m", "millicores") == 4000
      assert one.("0.2", "millicores") == 1
      # out of range for the unit, or not a number
      assert one.("4000", "cores") == nil
      assert one.("2000000", "millicores") == nil
      assert one.("0", "cores") == nil
      assert one.("four", "auto") == nil
    end

    test "the first name of the list that is present and readable wins, whatever the platform's order" do
      p = platform([{"cpu", "8"}, {"pool", "big"}, {"cores", "2"}])
      assert Cores.from_platform(p, %{names: ["cores", "cpu"], unit: "auto"}) == 2000
      assert Cores.from_platform(p, %{names: ["cpu", "cores"], unit: "auto"}) == 8000
      # present but not a number: the next name is tried
      assert Cores.from_platform(p, %{names: ["pool", "cores"], unit: "auto"}) == 2000
      assert Cores.from_platform(p, %{names: ["absent"], unit: "auto"}) == nil
      # a name outside the list is not read, even a built-in one
      assert Cores.from_platform(platform([{"cpu", "8"}]), %{names: ["cores"], unit: "auto"}) ==
               nil
    end

    test "the default is what it was" do
      assert Cores.from_platform(platform([{"EstimatedCPU", "2.5"}])) == 2500
      assert Cores.from_platform(platform([{"num_cpus", "4000m"}])) == 4000
      assert Cores.from_platform(platform([{"Pool", "4"}])) == nil
    end
  end

  describe "parsing with the project's declaration" do
    test "the worker reads the setting; without one a custom name is not cores", %{project: p} do
      inv = build!(p, 0)
      binary = log(inv, fn _ -> %{"runner-cores" => "3000"} end)

      {:ok, parsed} = ExecLog.parse(binary)
      assert Enum.all?(parsed.spawns, &is_nil(&1.platform_cores))

      {:ok, parsed} =
        ExecLog.parse(binary, cores_property: %{names: ["runner-cores"], unit: "millicores"})

      assert Enum.all?(parsed.spawns, &(&1.platform_cores == 3000))

      {:ok, blob} = Blobs.put(p, binary)
      Artifacts.attach(inv, "execution.log.zst", blob, "upload")

      {:ok, _} =
        Settings.put(p, %{"cores_properties" => "runner-cores", "cores_unit" => "millicores"})

      assert {:ok, 12} = perform_job(ParseExecLog, %{invocation_id: inv.id, project_id: p.id})

      assert Repo.all(
               from s in Spawn,
                 where: s.invocation_id == ^inv.id,
                 select: {s.cores_milli, s.cores_source}
             )
             |> Enum.uniq() == [{3000, Cores.exact()}]

      r = report(p)
      assert r.executed == %{n: 12, ms: 6000, core_ms: 18_000}

      assert Enum.all?(
               r.mnemonics,
               &(&1.cores_source == "exec property" and &1.exact_share == 1.0)
             )
    end
  end

  describe "coverage" do
    test "the share of executions and of wall time that state their cores", %{project: p} do
      inv = build!(p, 0)

      {:ok, parsed} =
        ExecLog.parse(log(inv, fn i -> if i < 3, do: %{"cores" => "2"}, else: %{} end))

      ExecLog.store!(inv, parsed)

      c = report(p).cores_coverage
      assert c.executed == %{n: 12, ms: 6000}
      assert c.exact == %{n: 3, ms: 1500}
      assert c.exact_share == 0.25
      assert c.fallbacks == [%{source: "default", n: 9, ms: 4500}]

      tests = Enum.find(report(p).mnemonics, &(&1.mnemonic == "TestRunner"))
      assert tests.exact_share > 0 and tests.exact_share < 1
    end

    test "hours summarized before counts per source existed give wall time only", %{project: p} do
      inv = build!(p, 0)
      {:ok, parsed} = ExecLog.parse(log(inv, fn _ -> %{"cores" => "2"} end))
      ExecLog.store!(inv, parsed)

      # wide enough for the build's hour to be a stored row
      wide = fn ->
        Report.build(
          %Scope{
            project_id: p.id,
            from: DateTime.add(@t0, -3, :hour),
            to: DateTime.add(@t0, 3, :hour)
          },
          settings: Settings.get(p)
        ).cores_coverage
      end

      assert wide.().exact == %{n: 12, ms: 6000}

      Repo.query!("UPDATE invocation_rollups SET rbe = rbe - 'srcn'")
      # the build's last change is older than the hour's row: the row is read as stored
      Repo.update_all(Invocation, set: [updated_at: ~U[2026-11-20 10:00:00.000000Z]])
      c = wide.()
      assert c.exact == %{n: nil, ms: 6000} and c.exact_share == 1.0 and c.fallbacks == []
    end
  end

  describe "property names seen in logs" do
    test "one row per name: spawns of the log, an example, nothing that looks like a secret",
         %{project: p} do
      inv = build!(p, 0)

      {:ok, parsed} =
        ExecLog.parse(
          log(inv, fn i ->
            %{
              "cores" => "4",
              "OSFamily" => "macos",
              "container-image" => "docker://registry.example/ci@sha256:abc",
              "api_token" => "abc123",
              "note" => "has spaces in it",
              "long" => String.duplicate("x", 41)
            }
            |> then(&if(i == 0, do: Map.put(&1, "rare", "1"), else: &1))
          end)
        )

      assert %{name: "cores", spawns: 12, sample: "4"} in parsed.properties
      ExecLog.store!(inv, parsed)

      rows = Map.new(Properties.list(p.id, 50), &{&1.name, {&1.spawns, &1.sample}})

      assert rows == %{
               "cores" => {12, "4"},
               "OSFamily" => {12, "macos"},
               "container-image" => {12, nil},
               "api_token" => {12, nil},
               "note" => {12, nil},
               "long" => {12, nil},
               "rare" => {1, "1"}
             }

      # most spawns first; the top of the list is what the page shows
      assert [%{spawns: 12}, %{spawns: 12}] = Properties.list(p.id, 2)
      refute inspect(Repo.all(Properties)) =~ "abc123"

      # the same log again changes nothing (no running total)
      ExecLog.store!(inv, parsed)
      assert Map.new(Properties.list(p.id, 50), &{&1.name, {&1.spawns, &1.sample}}) == rows
    end

    test "samples: short plain values only, never under a credential-like name or a URL" do
      assert Properties.sample("cores", " 4 ") == "4"
      assert Properties.sample("Pool", "linux/arm64:big+fast-1.2") == "linux/arm64:big+fast-1.2"
      assert Properties.sample("secret_key", "4") == nil
      assert Properties.sample("AUTH", "plain") == nil
      assert Properties.sample("image", "docker://x/y") == nil
      assert Properties.sample("x", "a b") == nil
      assert Properties.sample("x", "") == nil
      assert Properties.sample("x", String.duplicate("a", 41)) == nil
    end

    test "caps: fifty names per log, names that are long or not printable are left out" do
      tally =
        Enum.reduce(1..60, %{}, fn i, tally ->
          Enum.reduce(1..i, tally, fn _, tally ->
            Properties.observe(tally, platform([{"name-#{i}", "v"}]))
          end)
        end)
        |> Properties.observe(
          platform([{String.duplicate("n", 65), "v"}, {"with space", "v"}, {"", "v"}])
        )
        |> Properties.observe(nil)
        # a name twice on one spawn counts once
        |> Properties.observe(platform([{"name-60", "v"}, {"name-60", "w"}]))

      seen = Properties.summary(tally)
      assert length(seen) == 50
      assert hd(seen) == %{name: "name-60", spawns: 61, sample: "v"}
      assert Enum.all?(seen, &String.starts_with?(&1.name, "name-"))
      assert List.last(seen).name == "name-11"
    end

    test "a hundred names per project, the most recently seen; a fresh row is not rewritten",
         %{project: p} do
      seen = fn range -> for i <- range, do: %{name: "n#{i}", spawns: i, sample: nil} end
      assert Properties.record!(p.id, [], @t0) == :ok
      Properties.record!(p.id, seen.(1..50), @t0)
      Properties.record!(p.id, seen.(51..100), DateTime.add(@t0, 2, :hour))
      Properties.record!(p.id, seen.(101..120), DateTime.add(@t0, 4, :hour))

      names = p.id |> Properties.list(500) |> Enum.map(& &1.name)
      assert length(names) == 100
      assert hd(names) == "n120"
      # the oldest hour's least frequent names went
      refute "n1" in names
      assert "n50" in names and "n21" in names and "n20" not in names

      later = DateTime.add(@t0, 4 * 3600 + 60, :second)
      Properties.record!(p.id, [%{name: "n120", spawns: 7, sample: "x"}], later)

      assert [%{spawns: 120, sample: nil}] =
               Enum.filter(Properties.list(p.id, 500), &(&1.name == "n120"))

      much_later = DateTime.add(@t0, 5, :hour)
      Properties.record!(p.id, [%{name: "n120", spawns: 7, sample: "x"}], much_later)

      assert [%{spawns: 7, sample: "x", last_seen_at: ^much_later}] =
               Enum.filter(Properties.list(p.id, 500), &(&1.name == "n120"))

      # an example already known is kept when a later log has none to show
      Properties.record!(
        p.id,
        [%{name: "n120", spawns: 9, sample: nil}],
        DateTime.add(@t0, 6, :hour)
      )

      assert [%{spawns: 9, sample: "x"}] =
               Enum.filter(Properties.list(p.id, 500), &(&1.name == "n120"))
    end

    test "rows are a project's own and leave with it", %{project: p} do
      {:ok, other} = Projects.create_project(%{slug: "other-app", name: "Other app"})
      Properties.record!(other.id, [%{name: "theirs", spawns: 1, sample: "v"}], @t0)
      assert Properties.list(p.id) == []
      assert [%{name: "theirs"}] = Properties.list(other.id)
      Repo.delete!(other)
      assert Repo.all(Properties) == []
    end
  end

  describe "reading stored logs again" do
    test "the window's parsed builds with a stored log, most recent first, bounded", %{project: p} do
      {:ok, other} = Projects.create_project(%{slug: "other-app", name: "Other app"})
      from = DateTime.add(@t0, -60, :second)

      with_log = fn project, offset, status ->
        inv = build!(project, offset, %{exec_log_status: status})
        binary = log(inv, fn _ -> %{"runner-cores" => "2"} end)
        {:ok, parsed} = ExecLog.parse(binary)
        ExecLog.store!(inv, parsed)

        Repo.update_all(from(i in Invocation, where: i.id == ^inv.id),
          set: [exec_log_status: status]
        )

        {:ok, blob} = Blobs.put(project, binary)
        Artifacts.attach(inv, "execution.log.zst", blob, "upload")
        inv
      end

      a = with_log.(p, 0, "parsed")
      b = with_log.(p, 1000, "parsed")
      _expired = with_log.(p, 2000, "expired")
      _before = with_log.(p, -120_000, "parsed")
      _theirs = with_log.(other, 0, "parsed")
      # parsed, but its log is no longer attached
      gone = build!(p, 3000, %{exec_log_status: "parsed"})
      {:ok, blob} = Blobs.put(p, "not a log")
      Artifacts.attach(gone, "profile.json", blob, "upload")

      assert Reread.max() == 200
      assert Reread.count(p, from) == 2
      assert Reread.enqueue!(p, from) == 2

      jobs = all_enqueued(worker: ParseExecLog)
      assert Enum.sort(Enum.map(jobs, & &1.args["invocation_id"])) == Enum.sort([a.id, b.id])
      assert Enum.all?(jobs, &(&1.priority == 3 and &1.queue == "parse"))

      # asked again right away: the jobs are unique per build
      assert Reread.enqueue!(p, from) == 2
      assert length(all_enqueued(worker: ParseExecLog)) == 2

      # the parse with the new declaration changes the cores and no key, no class
      before = report(p)
      assert before.executed == %{n: 36, ms: 18_000, core_ms: 18_000}
      {:ok, _} = Settings.put(p, %{"cores_properties" => "runner-cores", "cores_unit" => "cores"})
      assert %{success: 2} = Oban.drain_queue(queue: :parse)

      after_ = report(p)
      assert after_.executed == %{n: 36, ms: 18_000, core_ms: 6000 + 2 * 12_000}
      assert after_.racing.total.n == before.racing.total.n
      assert after_.cache.gap.n == before.cache.gap.n
      assert after_.cores_coverage.exact == %{n: 24, ms: 12_000}
    end
  end
end
