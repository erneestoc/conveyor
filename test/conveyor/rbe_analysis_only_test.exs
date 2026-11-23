defmodule Conveyor.RbeAnalysisOnlyTest do
  @moduledoc """
  "Keep only what the duplicate-work metrics need" (PLAN §27.11): what a parse stores and
  deletes in that mode, the short row retention beside the keys' own, the freeze of an
  hour before its rows expire, late logs, and the freeze rule as a property over random
  orders of logs, summaries, passing time and retention. Builds are placed relative to
  the real clock; time passes through `:retention_clock_offset_s`.
  """
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo
  use ExUnitProperties

  alias Conveyor.{Artifacts, Blobs, ExecLog, ExecLogBuilder, Projects}
  alias Conveyor.ExecLog.{ActionKey, Spawn, SpawnInput}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.{Rollup, Scope}
  alias Conveyor.Rbe.{Report, Reread, Settings}
  alias Conveyor.Workers.{BuildRetention, ParseExecLog}

  setup do
    on_exit(fn -> Application.delete_env(:conveyor, :retention_clock_offset_s) end)
    {:ok, p} = Settings.put(Projects.ensure_default_project!(), %{"analysis_only" => "true"})
    %{project: p, t0: hours_ago(2)}
  end

  # The top of the hour that started at least `n` hours ago.
  defp hours_ago(n) do
    top = Rollup.truncate(DateTime.utc_now(), :hour)
    %{DateTime.add(top, -n * 3600, :second) | microsecond: {0, 6}}
  end

  defp pass(hours), do: Application.put_env(:conveyor, :retention_clock_offset_s, hours * 3600)

  defp build!(project, start) do
    Repo.insert!(%Invocation{
      id: Ecto.UUID.generate(),
      project_id: project.id,
      status: "succeeded",
      tags: %{},
      inserted_at: start,
      updated_at: start,
      started_at: start,
      finished_at: DateTime.add(start, 20, :second)
    })
  end

  # Uploads the build's log and runs the parse job, as CI and Oban do.
  defp upload!(project, inv) do
    binary = ExecLogBuilder.log(id: inv.id, base: inv.started_at)
    {:ok, blob} = Blobs.put(project, binary)
    Artifacts.attach(inv, "execution.log.zst", blob, "upload")
    assert {:ok, 12} = perform_job(ParseExecLog, %{invocation_id: inv.id, project_id: project.id})
    blob
  end

  defp scope(project, from),
    do: %Scope{
      from: from,
      to: DateTime.add(DateTime.utc_now(), 3 * 86_400),
      project_id: project.id
    }

  defp report(project, from) do
    project = Projects.get_project!(project.id)
    Report.build(scope(project, from), settings: Settings.get(project))
  end

  defp spawn_count(inv),
    do: Repo.aggregate(from(s in Spawn, where: s.invocation_id == ^inv.id), :count)

  test "the setting: off by default, days from 1 to 30, the late count survives a save", %{
    project: p
  } do
    fresh = Projects.ensure_default_project!() |> Map.put(:settings, %{})
    assert %{analysis_only: false, row_days: 3, late_logs: 0} = Settings.get(fresh)
    assert %{analysis_only: true, row_days: 3} = Settings.get(p)

    for bad <- ["0", "31", "x", "1.5"] do
      assert {:error, "spawn rows are kept" <> _} = Settings.put(p, %{"row_days" => bad})
    end

    {:ok, p} = Settings.put(p, %{"row_days" => "1"})
    # an attribute left out keeps what the project has
    assert %{analysis_only: true, row_days: 1} = Settings.get(p)
    assert p.settings["rbe"]["row_days"] == 1

    assert :ok = Settings.count_late!(p.id)
    assert :ok = Settings.count_late!(p.id)
    p = Projects.get_project!(p.id)
    assert Settings.get(p).late_logs == 2
    {:ok, p} = Settings.put(p, %{"row_days" => ""})
    assert %{row_days: 3, late_logs: 2, analysis_only: true} = Settings.get(p)
    refute Map.has_key?(p.settings["rbe"], "row_days")

    {:ok, p} = Settings.put(p, %{"analysis_only" => "false"})
    assert Settings.get(p).analysis_only == false
    refute Map.has_key?(p.settings["rbe"], "analysis_only")
  end

  test "rows are kept row_days, never longer than the retention; keys keep the retention", %{
    project: p
  } do
    now = DateTime.utc_now()
    assert ExecLog.retention_days(p) == 3
    assert ExecLog.general_retention_days(p) == 30
    {:ok, p} = Projects.put_storage(p, %{"spawn_retention_days" => "2"})
    assert ExecLog.retention_days(p) == 2
    assert ExecLog.key_retention_cutoff(p, now) == DateTime.add(now, -2, :day)
    {:ok, p} = Settings.put(p, %{"analysis_only" => "false"})
    assert ExecLog.retention_days(p) == 2
  end

  test "a parse stores no input lists and no output lists and deletes the uploaded log; the numbers are the same",
       %{project: p, t0: t0} do
    a = build!(p, t0)
    b = build!(p, DateTime.add(t0, 200, :millisecond))
    blob = upload!(p, a)
    upload!(p, b)

    assert Repo.aggregate(SpawnInput, :count) == 0
    spawns = Repo.all(from s in Spawn, where: s.invocation_id in ^[a.id, b.id])
    assert length(spawns) == 24
    assert Enum.all?(spawns, &(&1.outputs == %{}))
    # the digests the fallback key and the non-determinism check read are still there
    assert Enum.all?(spawns, &(&1.inputs_digest =~ ~r/^[0-9a-f]{64}$/))
    assert Enum.all?(spawns, &(&1.outputs_digest =~ ~r/^[0-9a-f]{64}$/))
    assert Enum.all?(spawns, &(&1.key_source == 1 and is_binary(&1.action_key)))

    # the uploaded log: artifact row and bytes
    assert Artifacts.list(a) == [] and Artifacts.list(b) == []
    assert Blobs.get(p, blob.digest) == nil
    assert Repo.get!(Invocation, a.id).exec_log_status == "parsed"
    assert Reread.count(p, DateTime.add(t0, -60)) == 0

    # the same golden numbers as a project that keeps everything (rbe_test.exs)
    r = report(p, DateTime.add(t0, -60))
    assert r.coverage == %{builds: 2, logs: 2}
    assert r.executed == %{n: 24, ms: 12_000, core_ms: 12_000}
    assert r.racing.remotable == %{n: 12, ms: 6000, core_ms: 6000}
    assert Settings.get(Projects.get_project!(p.id)).late_logs == 0
  end

  test "content another build still references keeps its bytes", %{project: p, t0: t0} do
    a = build!(p, t0)
    other = build!(p, DateTime.add(t0, 60))
    binary = ExecLogBuilder.log(id: a.id, base: a.started_at)
    {:ok, blob} = Blobs.put(p, binary)
    Artifacts.attach(a, "execution.log.zst", blob, "upload")
    Artifacts.attach(other, "copy-of-a.bin", blob, "upload")
    assert {:ok, 12} = perform_job(ParseExecLog, %{invocation_id: a.id, project_id: p.id})
    assert Artifacts.list(a) == []
    assert [%{name: "copy-of-a.bin"}] = Artifacts.list(other)
    assert Blobs.get(p, blob.digest)
  end

  test "why did it run: a changed input digest is reported, the input diff is not kept", %{
    project: p,
    t0: t0
  } do
    a = build!(p, t0)
    b = build!(p, DateTime.add(t0, 60))
    upload!(p, a)
    upload!(p, b)

    {1, _} =
      Repo.update_all(
        from(s in Spawn, where: s.invocation_id == ^b.id and s.ordinal == 0),
        set: [inputs_digest: String.duplicate("f", 64)]
      )

    explained = ExecLog.explain(Repo.get!(Invocation, b.id))
    assert explained.inputs_kept? == false
    assert explained.counts == %{inputs_changed: 1, same_inputs: 11}
    changed = Enum.find(explained.rows, &(&1.reason == :inputs_changed))
    assert %{inputs_kept?: false, added: [], removed: [], changed: []} = changed

    {:ok, _} = Settings.put(p, %{"analysis_only" => "false"})
    assert ExecLog.explain(Repo.get!(Invocation, b.id)).inputs_kept?
  end

  test "retention with the clock moved: rows go, numbers and keys stay, later builds still match",
       %{project: p, t0: t0} do
    {:ok, p} = Settings.put(p, %{"row_days" => "1"})
    from = DateTime.add(t0, -60)
    a = build!(p, t0)
    b = build!(p, DateTime.add(t0, 200, :millisecond))
    upload!(p, a)
    upload!(p, b)
    before = report(p, from)
    assert before.racing.remotable.n == 12

    # 27 hours later (the builds are 2 to 3 hours old): past one day of rows
    pass(27)
    assert ExecLog.frozen?(p, t0)
    assert {:ok, %{projects: projects}} = perform_job(BuildRetention, %{})
    assert projects[p.slug].expired == 2
    assert spawn_count(a) == 0 and spawn_count(b) == 0
    assert Repo.get!(Invocation, a.id).exec_log_status == "expired"
    # the keys keep the execution-log retention (30 days), not the row days
    assert Repo.aggregate(from(k in ActionKey, where: k.scope == ^p.id), :count) == 12

    same? = fn r ->
      Map.take(r, [:executed, :racing, :cache, :mnemonics]) ==
        Map.take(before, [:executed, :racing, :cache, :mnemonics])
    end

    assert same?.(report(p, from))

    # the frozen hour is stale again (a build of it changed): it is not computed from
    # rows that are gone
    Repo.update_all(from(i in Invocation, where: i.id == ^a.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), 60)]
    )

    assert same?.(report(p, from))

    # a build of "now" (27 hours on) repeats the actions: sequential after the first
    # executions, whose rows are gone and whose keys are not
    later = build!(p, DateTime.add(DateTime.utc_now(), 27 * 3600 - 600))
    upload!(p, later)
    r = report(p, from)
    assert r.cache.gap == %{n: 12, ms: 6000, core_ms: 6000}
    assert r.racing.remotable == before.racing.remotable
    assert r.executed.n == 36

    # a log for a build of the frozen hour arrives now: late. Its keys are merged, its
    # executions are in no number, and it is counted
    late = build!(p, DateTime.add(t0, 600))
    upload!(p, late)
    assert Settings.get(Projects.get_project!(p.id)).late_logs == 1
    assert report(p, from).executed.n == 36

    # back to keeping everything, with the clock where it was: the hour is not frozen by
    # age any more, but its builds are marked expired, so it still is not computed again
    pass(0)
    {:ok, p} = Settings.put(p, %{"analysis_only" => "false"})
    refute ExecLog.frozen?(p, t0)

    Repo.update_all(from(i in Invocation, where: i.id == ^b.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), 120)]
    )

    assert report(p, from).racing.remotable == before.racing.remotable
  end

  test "the rollup job checks the whole row window of an analysis-only project", %{project: p} do
    # two and a half days old: outside the job's two days, inside the three days of rows
    old = build!(p, DateTime.add(hours_ago(60), 300))
    assert {:ok, n} = perform_job(Conveyor.Workers.Rollup, %{})
    assert n >= 1
    ExecLog.store!(old, parsed(old))
    assert {:ok, 1} = perform_job(Conveyor.Workers.Rollup, %{})
    row = Repo.get_by!(Rollup.Row, project_id: p.id, hour: hours_ago(60))
    assert row.rbe["builds"] == 1
  end

  defp parsed(inv) do
    {:ok, parsed} =
      ExecLog.parse(ExecLogBuilder.log(id: inv.id, base: inv.started_at), analysis_only: true)

    parsed
  end

  # --- the freeze rule as a property -----------------------------------------------------------
  #
  # Four builds of the same twelve actions over three hours, rows kept one day. Any order
  # of: a build's log is parsed; the page is read (stale hours are summarized); hours
  # pass, the rollup job having run just before (it runs every five minutes); retention
  # runs. Then, after every step:
  #
  #   1. an hour that is not frozen holds exactly the logs parsed for its builds while it
  #      was not frozen (12 spawns each): it was computed from all of their rows;
  #   2. an hour that is frozen holds what it held when it was last summarized before it
  #      froze, whatever was parsed, expired or read since;
  #   3. with no late log, the window is exact: one first execution per action, every
  #      other execution a duplicate.

  defp ops do
    op =
      one_of([
        tuple({constant(:log), integer(0..3)}),
        constant(:read),
        tuple({constant(:pass), member_of([1, 20, 22, 23, 24, 30])}),
        constant(:retention)
      ])

    list_of(op, min_length: 3, max_length: 12)
  end

  defp count(rbe, classes) do
    for class <- classes, {_mnemonic, [n | _]} <- get_in(rbe || %{}, ["mn", class]) || %{} do
      n
    end
    |> Enum.sum()
  end

  @executed ~w(first racing racing_x seq seq_x)

  property "an hour is never summarized from part of its rows; frozen hours keep their last full summary" do
    t0 = hours_ago(2)
    starts = [0, 1200, 3600 + 600, 7200 + 60] |> Enum.map(&DateTime.add(t0, &1))

    check all(ops <- ops(), max_runs: 25) do
      pass(0)
      slug = "freeze-#{System.unique_integer([:positive])}"
      {:ok, p} = Projects.create_project(%{slug: slug, name: slug})
      {:ok, p} = Settings.put(p, %{"analysis_only" => "true", "row_days" => "1"})
      builds = Enum.map(starts, &build!(p, &1))
      window = %{scope(p, DateTime.add(t0, -60)) | stored: true}
      hour_of = fn inv -> Rollup.truncate(inv.started_at, :hour) |> DateTime.to_unix() end

      rows = fn ->
        Map.new(Rollup.rows(window), &{DateTime.to_unix(&1.hour), &1.rbe})
      end

      init = %{offset: 0, in_time: %{}, late: 0, stored: MapSet.new(), frozen: %{}, last: rows.()}

      final =
        Enum.reduce(ops, init, fn op, st ->
          st =
            case op do
              {:log, i} ->
                inv = Enum.at(builds, i)

                if i in st.stored do
                  st
                else
                  late? = ExecLog.frozen?(p, inv.started_at)
                  ExecLog.store!(inv, parsed(inv))
                  st = %{st | stored: MapSet.put(st.stored, i)}

                  if late?,
                    do: %{st | late: st.late + 1},
                    else: %{st | in_time: Map.update(st.in_time, hour_of.(inv), 1, &(&1 + 1))}
                end

              :read ->
                st

              {:pass, hours} ->
                # the rollup job ran before the hours passed
                last = rows.()
                pass(st.offset + hours)
                %{st | offset: st.offset + hours, last: last}

              :retention ->
                ExecLog.expire_before(p, ExecLog.retention_cutoff(p))
                st
            end

          now = rows.()

          Enum.reduce(now, st, fn {hour, rbe}, st ->
            if ExecLog.frozen?(p, DateTime.from_unix!(hour)) do
              expected = Map.get_lazy(st.frozen, hour, fn -> st.last[hour] end)
              assert rbe == expected, "a frozen hour changed after #{inspect(op)}"
              %{st | frozen: Map.put(st.frozen, hour, expected)}
            else
              logs = Map.get(st.in_time, hour, 0)
              assert ((rbe || %{})["builds"] || 0) == logs
              assert count(rbe, @executed) == 12 * logs
              %{st | last: Map.put(st.last, hour, rbe)}
            end
          end)
        end)

      if final.late == 0 and MapSet.size(final.stored) > 0 do
        total = Rollup.combine(Rollup.rows(window)).rbe
        assert count(total, ["first"]) == 12
        assert count(total, @executed) == 12 * MapSet.size(final.stored)
      end
    end
  end
end
