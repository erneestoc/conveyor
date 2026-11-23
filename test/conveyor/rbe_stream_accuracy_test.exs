defmodule Conveyor.Rbe.StreamAccuracyTest do
  @moduledoc """
  What makes the stream figures trustworthy: recorded builds (Bazel 9.2 with
  `--build_event_publish_all_actions`; buildtools and abseil) go through the real ingest
  path, key merge, rollup and report, and are compared with the classification of the
  compact execution logs of the same builds, computed here by brute force from the
  action digests (the ground truth).

    * at one commit the same-commit figure equals the truth, class by class;
    * across commits: same-commit ≤ truth ≤ any-commit, and the over-count is printed;
    * executed and hit counts equal the log's.
  """
  use Conveyor.IngestCase, async: false

  alias Conveyor.ExecLog
  alias Conveyor.ExecLog.ActionKey
  alias Conveyor.Metrics.Scope
  alias Conveyor.Rbe.{Report, Settings, Stream}
  alias Conveyor.StreamFixture

  @moduletag :capture_log

  # Builds are placed a few hours ago: inside every retention, in hours not yet frozen.
  defp base, do: DateTime.utc_now() |> DateTime.add(-4 * 3600, :second) |> truncate()
  defp truncate(dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 6}}

  # Ingests the builds `{fixture, start offset in seconds, commit}` and returns the report
  # with the truth of the same builds.
  defp run(ctx, builds) do
    base = base()

    truth =
      for {{name, offset, commit}, n} <- Enum.with_index(builds) do
        start = DateTime.add(base, offset, :second)
        shift = DateTime.diff(start, StreamFixture.started_at(name), :microsecond)
        tags = if commit, do: %{"commit" => commit}, else: %{}
        StreamFixture.ingest!(ctx, StreamFixture.events(name, shift_us: shift, tags: tags))
        {:ok, %{spawns: spawns}} = ExecLog.parse(StreamFixture.log(name))

        for s <- spawns do
          %{
            build: n,
            hit: s.cache_hit,
            execution: ActionKey.execution?(s),
            key: s.action_key,
            ms: s.total_ms || 0,
            start: s.started_at && DateTime.add(s.started_at, shift, :microsecond),
            ordinal: s.ordinal
          }
        end
      end
      |> List.flatten()

    assert Stream.merge_pending!(DateTime.add(base, -3600, :second)) == length(builds)

    scope = %Scope{
      from: DateTime.add(base, -3600, :second),
      to: DateTime.add(base, 4 * 3600, :second),
      project_id: ctx.project_id
    }

    project = Conveyor.Projects.get_project!(ctx.project_id)
    {Report.build(scope, settings: Settings.get(project)).stream, truth(truth)}
  end

  # First finisher per digest; started before it finished: racing; after: sequential.
  defp truth(spawns) do
    executions = Enum.filter(spawns, & &1.execution)
    finish = &DateTime.add(&1.start, &1.ms, :millisecond)

    rank =
      &{DateTime.to_unix(finish.(&1), :microsecond), DateTime.to_unix(&1.start, :microsecond),
       &1.build, &1.ordinal}

    classes =
      executions
      |> Enum.group_by(& &1.key)
      |> Enum.flat_map(fn {_key, execs} ->
        [first | rest] = Enum.sort_by(execs, rank)

        [
          {:first, first}
          | Enum.map(rest, fn e ->
              {if(DateTime.compare(e.start, finish.(first)) == :lt,
                 do: :racing,
                 else: :sequential
               ), e}
            end)
        ]
      end)

    cell = fn class ->
      es = for {^class, e} <- classes, do: e
      %{n: length(es), ms: es |> Enum.map(& &1.ms) |> Enum.sum()}
    end

    %{
      executed: Enum.count(spawns, &(not &1.hit)),
      hits: Enum.count(spawns, & &1.hit),
      first: cell.(:first),
      racing: cell.(:racing),
      sequential: cell.(:sequential)
    }
  end

  # Equal counts; times equal up to the log's rounding (it keeps whole milliseconds).
  defp same!(cell, truth) do
    assert cell.n == truth.n
    assert_in_delta cell.ms, truth.ms, max(truth.n, 1)
  end

  defp line(name, t, floor, ceiling) do
    s = &:erlang.float_to_binary(&1 / 1000, decimals: 1)
    dup = &(&1.racing.ms + &1.sequential.ms)

    over =
      if dup.(t) > 0,
        do: "#{Float.round((dup.(ceiling) - dup.(t)) * 100 / dup.(t), 1)} %",
        else: "#{s.(dup.(ceiling))} s of none"

    IO.puts(
      "accuracy | #{String.pad_trailing(name, 34)} | truth seq #{s.(t.sequential.ms)} s (#{t.sequential.n}) racing #{s.(t.racing.ms)} s (#{t.racing.n})" <>
        " | floor seq #{s.(floor.sequential.ms)} s (#{floor.sequential.n}) racing #{s.(floor.racing.ms)} s (#{floor.racing.n})" <>
        " | ceiling seq #{s.(ceiling.sequential.ms)} s (#{ceiling.sequential.n}) racing #{s.(ceiling.racing.ms)} s (#{ceiling.racing.n})" <>
        " | over-count #{over}"
    )
  end

  defp counts!(report, truth) do
    assert report.executed.n == truth.executed
    assert report.hits.n == truth.hits
  end

  for {repo, gap, lag} <- [{"buildtools", 600, 1}, {"abseil", 900, 7}] do
    test "#{repo}: one commit on two machines, one after the other", %{ctx: ctx} do
      repo = unquote(repo)
      {r, t} = run(ctx, [{"#{repo}_a1", 0, "c1"}, {"#{repo}_b1", unquote(gap), "c1"}])
      line("#{repo}, same commit, sequential", t, r.same_commit, r.any_commit)
      counts!(r, t)
      assert t.racing.n == 0 and t.sequential.n > 100

      for figure <- [r.same_commit, r.any_commit] do
        same!(figure.first, t.first)
        same!(figure.sequential, t.sequential)
        same!(figure.racing, t.racing)
      end

      assert r.builds == 2 and r.counts_only_builds == 0 and r.no_commit_builds == 0
      assert r.coverage == %{builds: 2, with_events: 2}
    end

    test "#{repo}: one commit on two machines at once", %{ctx: ctx} do
      repo = unquote(repo)
      {r, t} = run(ctx, [{"#{repo}_a1", 0, "c1"}, {"#{repo}_b1", unquote(lag), "c1"}])
      line("#{repo}, same commit, racing", t, r.same_commit, r.any_commit)
      counts!(r, t)
      assert t.racing.n > 0

      for figure <- [r.same_commit, r.any_commit] do
        same!(figure.first, t.first)
        same!(figure.sequential, t.sequential)
        same!(figure.racing, t.racing)
      end
    end
  end

  test "buildtools: cold, then warm from the cache: hits are not executions", %{ctx: ctx} do
    {r, t} = run(ctx, [{"buildtools_a1", 0, "c1"}, {"buildtools_a1_warm", 600, "c1"}])
    line("buildtools, cold then warm", t, r.same_commit, r.any_commit)
    counts!(r, t)
    assert t.hits == 199 and r.hits.ms > 0
    assert r.same_commit.duplicate.n == 0 and r.any_commit.duplicate.n == 0
    same!(r.same_commit.first, t.first)
  end

  test "buildtools: a Go change between two commits", %{ctx: ctx} do
    {r, t} = run(ctx, [{"buildtools_a1", 0, "c1"}, {"buildtools_a2", 600, "c2"}])
    line("buildtools, Go change, two commits", t, r.same_commit, r.any_commit)
    counts!(r, t)
    bounds!(r, t)
    assert r.same_commit.duplicate.n == 0
  end

  test "abseil: a C++ header change between two commits", %{ctx: ctx} do
    {r, t} = run(ctx, [{"abseil_a1", 0, "c1"}, {"abseil_b2", 900, "c2"}])
    line("abseil, header change, two commits", t, r.same_commit, r.any_commit)
    counts!(r, t)
    bounds!(r, t)
    assert t.sequential.n > 300
    assert r.same_commit.duplicate.n == 0
    # The ceiling counts every execution of the second build: the changed header is in
    # no command line.
    assert r.any_commit.sequential.n > t.sequential.n
  end

  test "without a commit only the any-commit figure exists", %{ctx: ctx} do
    {r, t} = run(ctx, [{"buildtools_a1", 0, nil}, {"buildtools_b1", 600, nil}])
    counts!(r, t)
    same!(r.any_commit.sequential, t.sequential)
    assert r.no_commit_builds == 2
    assert r.same_commit.duplicate.n == 0 and r.same_commit.first.n == 0
    assert r.same_commit.no_commit.n == t.executed
  end

  # floor ≤ truth ≤ ceiling, in count and in time, for both classes together.
  defp bounds!(r, t) do
    truth_n = t.racing.n + t.sequential.n
    truth_ms = t.racing.ms + t.sequential.ms
    assert r.same_commit.duplicate.n <= truth_n and truth_n <= r.any_commit.duplicate.n
    assert r.same_commit.duplicate.ms <= truth_ms + truth_n
    assert truth_ms <= r.any_commit.duplicate.ms + truth_n
  end
end
