defmodule Conveyor.Rbe.StreamTest do
  @moduledoc """
  The stream figures around the edges (PLAN §28): builds that arrive out of order, a
  build that also has a parsed execution log, builds without times, a cache group over
  two projects, retention and the freeze of summarized hours. Recorded builds through
  the real ingest path; the numbers are those of the accuracy test (199 executions per
  buildtools build).
  """
  use Conveyor.IngestCase, async: false

  import Ecto.Query

  alias Conveyor.{ExecLog, Projects}
  alias Conveyor.ExecLog.{ActionKey, Keys}
  alias Conveyor.Ingest.Context
  alias Conveyor.Metrics.Scope
  alias Conveyor.Rbe.{Groups, Report, Settings, Stream, StreamChunk}
  alias Conveyor.StreamFixture

  @moduletag :capture_log

  setup do
    on_exit(fn -> Application.delete_env(:conveyor, :retention_clock_offset_s) end)
    base = DateTime.utc_now() |> DateTime.add(-4 * 3600, :second)
    %{base: %{base | minute: 0, second: 0, microsecond: {0, 6}}}
  end

  defp ingest(ctx, base, name, offset, commit \\ "c1") do
    start = DateTime.add(base, offset, :second)
    shift = DateTime.diff(start, StreamFixture.started_at(name), :microsecond)
    tags = if commit, do: %{"commit" => commit}, else: %{}
    StreamFixture.ingest!(ctx, StreamFixture.events(name, shift_us: shift, tags: tags))
  end

  defp merge(base), do: Stream.merge_pending!(DateTime.add(base, -3600, :second))

  defp report(base, project_or_ids, hours \\ 4) do
    scope = %Scope{
      from: DateTime.add(base, -3600, :second),
      to: DateTime.add(base, hours * 3600, :second)
    }

    case project_or_ids do
      ids when is_list(ids) ->
        Report.build(%{scope | project_ids: ids},
          settings: Settings.get(Projects.get_project!(hd(ids)))
        )

      id ->
        Report.build(%{scope | project_id: id}, settings: Settings.get(Projects.get_project!(id)))
    end
  end

  defp chunks(id),
    do: Repo.aggregate(from(c in StreamChunk, where: c.invocation_id == ^id), :count)

  test "a build that arrives after a later one takes over the first executions", %{
    ctx: ctx,
    base: base,
    project: p
  } do
    later = ingest(ctx, base, "buildtools_b1", 600)
    assert merge(base) == 1
    r = report(base, p.id).stream
    assert r.any_commit.first.n == 199 and r.any_commit.duplicate.n == 0
    assert r.builds == 1 and r.pending_builds == 0
    # (A rollup stamps its row five seconds back; stamped now, only a touch after this
    # makes the hour be computed again.)
    Repo.update_all(Conveyor.Metrics.Rollup.Row, set: [updated_at: DateTime.utc_now()])

    # The build that ran first arrives second; until its keys are merged it is pending.
    earlier = ingest(ctx, base, "buildtools_a1", 0)
    assert %{builds: 1, pending_builds: 1} = report(base, p.id).stream
    Repo.update_all(Conveyor.Metrics.Rollup.Row, set: [updated_at: DateTime.utc_now()])
    assert merge(base) == 1

    for figure <- [:any_commit, :same_commit] do
      r = Map.fetch!(report(base, p.id).stream, figure)
      assert r.first.n == 199 and r.sequential.n == 199 and r.racing.n == 0
    end

    # Every key row names the earlier build; a second merge changes nothing; the build's
    # chunks are one row.
    firsts =
      Repo.all(
        from k in ActionKey,
          # (not the rows of single executions: each names its own build)
          where: k.scope == ^p.id and k.out != 2,
          select: k.first_invocation_id,
          distinct: true
      )

    assert firsts == [earlier]
    before = report(base, p.id).stream
    assert :ok = Stream.merge_keys!(reload(earlier))
    assert :ok = Stream.merge_keys!(reload(later))
    assert report(base, p.id).stream == before
    assert chunks(earlier) == 1 and chunks(later) == 1
    assert ActionKey.source_name(Conveyor.Rbe.StreamActions.key_source()) == "stream"
  end

  test "a build with a parsed execution log is reported from the log, not from its records", %{
    ctx: ctx,
    base: base,
    project: p
  } do
    ingest(ctx, base, "buildtools_a1", 0)
    logged = ingest(ctx, base, "buildtools_b1", 600)
    assert merge(base) == 2
    r = report(base, p.id)
    assert r.source == "stream" and r.stream.any_commit.sequential.n == 199

    {:ok, parsed} = ExecLog.parse(StreamFixture.log("buildtools_b1"))
    ExecLog.store!(reload(logged), parsed)

    r = report(base, p.id)
    assert r.source == "both"
    assert r.coverage.logs == 1
    assert %{builds: 1, logged_builds: 1, coverage: %{builds: 2, with_events: 2}} = r.stream
    assert r.stream.executed.n == 199 and r.stream.any_commit.duplicate.n == 0
    assert r.executed.n == 199
    assert Report.to_json(r)["stream"]["same_commit"]["first"]["n"] == 199
  end

  test "builds without usable times are counted only", %{ctx: ctx, base: base, project: p} do
    assert report(base, p.id).source == "none"
    assert report(base, p.id).stream == nil

    ingest(ctx, base, "bazel_7_6", 0)
    ingest(ctx, base, "bazel_8_4", 60)
    assert {:ok, _} = Conveyor.Workers.Rollup.perform(%Oban.Job{args: %{}})
    r = report(base, p.id).stream
    assert %{builds: 2, counts_only_builds: 2, untimed: 30} = r
    assert r.executed.n == 0 and r.hits.n == 0

    # Bazel 8.6: the two spawns of the build are timed, the internal actions are not.
    ingest(ctx, base, "bazel_8_6", 120, nil)
    assert merge(base) == 1
    r = report(base, p.id).stream
    assert %{builds: 3, counts_only_builds: 2, no_commit_builds: 1, untimed: 43} = r
    assert r.executed.n == 2 and r.executed.core_ms >= r.executed.ms
  end

  test "a cache group: what another project finished first is a cross-project duplicate", %{
    ctx: ctx,
    base: base,
    project: p
  } do
    {:ok, other} = Projects.create_project(%{slug: "stream-other", name: "Other"})
    {:ok, p} = Groups.put(p, "stream-group")
    {:ok, other} = Groups.put(other, "stream-group")
    other_ctx = %Context{project_id: other.id, project_slug: other.slug}

    ingest(ctx, base, "buildtools_a1", 0)
    ingest(other_ctx, base, "buildtools_b1", 600)
    assert merge(base) == 2

    mine = report(base, p.id).stream.any_commit
    assert mine.first.n == 199 and mine.duplicate.n == 0

    theirs = report(base, other.id).stream
    assert theirs.any_commit.sequential.n == 199 and theirs.any_commit.cross_project.n == 199
    assert theirs.same_commit.cross_project.n == 199 and theirs.any_commit.first.n == 0

    both = report(base, [p.id, other.id]).stream
    assert both.any_commit.first.n == 199 and both.any_commit.sequential.n == 199
    assert both.coverage == %{builds: 2, with_events: 2}
  end

  test "records expire after the row days; summarized hours keep their numbers; keys stay", %{
    ctx: ctx,
    base: base,
    project: p
  } do
    a = ingest(ctx, base, "buildtools_a1", 0)
    b = ingest(ctx, base, "buildtools_b1", 600)
    assert merge(base) == 2
    before = report(base, p.id).stream
    assert before.any_commit.sequential.n == 199
    assert Stream.days(p) == 3
    refute Stream.frozen?(p.id, base)

    # Three days pass.
    Application.put_env(:conveyor, :retention_clock_offset_s, 3 * 86_400)
    assert Stream.frozen?(p.id, base)
    assert {:ok, _} = Conveyor.Workers.BuildRetention.perform(%Oban.Job{})
    assert Stream.records(a) == [] and Stream.records(b) == []
    # per build 199 any-commit rows (shared), and of its own: same commit shared, one
    # per execution
    assert Repo.aggregate(from(k in ActionKey, where: k.scope == ^p.id), :count) == 796

    # The hours are rolled again (something touched their builds) and hold what they held.
    Keys.touch!([a, b], DateTime.utc_now())
    assert report(base, p.id).stream == before

    # A build three days later is matched against first executions whose records are gone.
    ingest(ctx, base, "buildtools_b1", 3 * 86_400 + 3 * 3600)
    assert merge(base) == 1
    r = report(base, p.id, 3 * 24 + 5).stream
    assert r.any_commit.first.n == 199 and r.any_commit.sequential.n == 398
    assert r.same_commit.sequential.n == 398

    # Two days after the records, the same-commit rows go; the any-commit rows stay.
    # (The last build finished on day 3: its day is kept until day 3 + 3 + 2.)
    Application.put_env(:conveyor, :retention_clock_offset_s, 9 * 86_400)
    assert {:ok, _} = Conveyor.Workers.BuildRetention.perform(%Oban.Job{})
    assert Repo.aggregate(from(k in ActionKey, where: k.scope == ^p.id), :count) == 199

    assert Repo.aggregate(from(k in ActionKey, where: k.scope == ^p.id and k.out == 1), :count) ==
             0

    # A build of that commit after that starts over at its commit and still repeats the
    # key at any commit.
    late = ingest(ctx, base, "buildtools_a1", 9 * 86_400 + 3 * 3600)
    assert merge(base) == 1

    [any, same] =
      late
      |> Stream.records()
      |> Stream.entries("c1")
      |> Enum.split_with(&(&1.out == "0000000000000000"))
      |> Tuple.to_list()

    # (same commit and one per execution)
    assert length(any) == 199 and length(same) == 398

    assert Repo.aggregate(from(k in ActionKey, where: k.scope == ^p.id and k.out == 1), :count) ==
             199
  end
end
