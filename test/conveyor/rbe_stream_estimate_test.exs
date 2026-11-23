defmodule Conveyor.Rbe.StreamEstimateTest do
  @moduledoc """
  The estimate between the same-commit floor and the any-commit ceiling (PLAN §28.4),
  on the recorded builds: what it says against the truth of the execution logs (brute
  force by action digest), and that it never leaves the bracket.

  One build here is constructed, and says so: "warm" is the recorded cold build of the
  second commit with the actions whose digest the first commit's log also has turned
  into cache hits carrying the first build's times, which is what Bazel sends for a hit
  (the recorded warm buildtools builds are the check of that: their hits carry the cold
  build's start times to the microsecond).
  """
  use Conveyor.IngestCase, async: false

  alias Conveyor.ExecLog
  alias Conveyor.ExecLog.ActionKey
  alias Conveyor.Metrics.Scope
  alias Conveyor.Rbe.{Report, Settings, Stream}
  alias Conveyor.StreamFixture

  @moduletag :capture_log

  defp base, do: DateTime.utc_now() |> DateTime.add(-4 * 3600, :second) |> truncate()
  defp truncate(dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 6}}

  defp shift(base, name, offset),
    do:
      base
      |> DateTime.add(offset, :second)
      |> DateTime.diff(StreamFixture.started_at(name), :microsecond)

  defp spawns(name),
    do: name |> StreamFixture.log() |> ExecLog.parse() |> elem(1) |> Map.fetch!(:spawns)

  # `{fixture, offset s, commit}` or `{fixture, offset s, commit, {:warm, fixture, offset s}}`.
  defp run(ctx, builds) do
    base = base()

    truth =
      for {build, n} <- Enum.with_index(builds) do
        {name, offset, commit} = {elem(build, 0), elem(build, 1), elem(build, 2)}
        shift = shift(base, name, offset)
        # The hits of a recorded warm build are those of the build recorded before it.
        hits_shift =
          case build do
            {_, _, _, {:hits, from, from_offset}} -> shift(base, from, from_offset)
            _ -> shift
          end

        events =
          StreamFixture.events(name,
            shift_us: shift,
            hits_shift_us: hits_shift,
            tags: %{"commit" => commit}
          )

        spawns = spawns(name)

        {events, cached} =
          case build do
            {_, _, _, {:warm, from, from_offset}} ->
              warm(events, spawns, from, shift(base, from, from_offset))

            _ ->
              {events, MapSet.new()}
          end

        StreamFixture.ingest!(ctx, events)

        for s <- spawns do
          hit = s.cache_hit or MapSet.member?(cached, s.action_key)

          %{
            build: n,
            hit: hit,
            execution: ActionKey.execution?(s) and not hit,
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

  # The recorded build as a machine holding `from`'s results would have run it: an action
  # whose digest `from`'s log has is a hit with the times `from`'s stream gave it.
  defp warm(events, spawns, from, from_shift) do
    earlier =
      from |> spawns() |> Enum.filter(&ActionKey.execution?/1) |> MapSet.new(& &1.action_key)

    unchanged =
      for s <- spawns,
          ActionKey.execution?(s),
          MapSet.member?(earlier, s.action_key),
          into: %{} do
        {at(s.mnemonic, s.target_label, s.primary_output), s.action_key}
      end

    times =
      for %{id: %{id: {:action_completed, aid}}, payload: {:action, a}} <-
            StreamFixture.events(from, shift_us: from_shift),
          a.start_time != nil,
          into: %{},
          do: {at(a.type, aid.label, aid.primary_output), {a.start_time, a.end_time}}

    events =
      Enum.map(events, fn
        %{id: %{id: {:action_completed, aid}}, payload: {:action, a}} = e ->
          at = at(a.type, aid.label, aid.primary_output)

          case unchanged[at] && times[at] do
            {start_time, end_time} ->
              %{e | payload: {:action, %{a | start_time: start_time, end_time: end_time}}}

            _ ->
              e
          end

        e ->
          e
      end)

    cached =
      for s <- spawns, MapSet.member?(earlier, s.action_key), into: MapSet.new(), do: s.action_key

    {events, cached}
  end

  # What joins an event to its spawn in the log: the primary output; for a test, whose
  # event names another output than the log, the target.
  defp at("TestRunner", label, _output), do: {"TestRunner", label}
  defp at(mnemonic, _label, output), do: {mnemonic, output}

  defp truth(spawns) do
    executions = Enum.filter(spawns, & &1.execution)
    finish = &DateTime.add(&1.start, &1.ms, :millisecond)

    rank =
      &{DateTime.to_unix(finish.(&1), :microsecond), DateTime.to_unix(&1.start, :microsecond),
       &1.build, &1.ordinal}

    dups =
      executions
      |> Enum.group_by(& &1.key)
      |> Enum.flat_map(fn {_key, execs} -> execs |> Enum.sort_by(rank) |> tl() end)

    %{
      n: length(dups),
      ms: dups |> Enum.map(& &1.ms) |> Enum.sum(),
      executed: length(executions),
      hits: Enum.count(spawns, & &1.hit)
    }
  end

  defp between!(lo, x, hi) when is_number(lo) and is_number(x) and is_number(hi),
    do: assert(lo <= x and x <= hi)

  defp s(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)
  defp cell(nil), do: "none"
  defp cell(c), do: "#{s(c.ms)} s (#{c.n})"

  defp line(name, r, t) do
    estimate = r.estimate && r.estimate.duplicate

    IO.puts(
      "estimate | #{String.pad_trailing(name, 44)} | truth #{s(t.ms)} s (#{t.n})" <>
        " | floor #{cell(r.same_commit.duplicate)} | estimate #{cell(estimate)}" <>
        " | ceiling #{cell(r.any_commit.duplicate)}"
    )

    if estimate do
      between!(r.same_commit.duplicate.n, estimate.n, r.any_commit.duplicate.n)
      between!(r.same_commit.duplicate.ms, estimate.ms, r.any_commit.duplicate.ms)
    end

    between!(r.same_commit.duplicate.n, t.n, r.any_commit.duplicate.n)
    estimate
  end

  test "buildtools, Go change on a warm machine: every repeat is proven different", %{ctx: ctx} do
    {r, t} =
      run(ctx, [
        {"buildtools_a1", 0, "c1"},
        {"buildtools_a2", 600, "c2", {:hits, "buildtools_a1", 0}}
      ])

    e = line("buildtools, Go change, warm machine", r, t)
    assert t.n == 0 and r.any_commit.duplicate.n == 12
    assert e.n == 0 and e.ms == 0
    assert r.estimate.evidence.different.n == 12 and r.estimate.evidence.unknown.n == 0
    # The recorded hits carry the first build's start times: each one is linked.
    assert r.estimate.evidence.unchanged.n == r.hits.n and r.hits.n == t.hits
  end

  test "abseil, header change, two cold machines: nothing to estimate from", %{ctx: ctx} do
    {r, t} = run(ctx, [{"abseil_a1", 0, "c1"}, {"abseil_b2", 900, "c2"}])
    assert line("abseil, header change, two cold machines", r, t) == nil
    assert r.any_commit.duplicate.n == 622 and t.n == 387
  end

  test "buildtools, a commit that changes nothing: warm, then a cold machine", %{ctx: ctx} do
    {r, t} =
      run(ctx, [
        {"buildtools_a1", 0, "c1"},
        {"buildtools_a1_warm", 600, "c2", {:hits, "buildtools_a1", 0}},
        {"buildtools_b1", 1200, "c2"}
      ])

    e = line("buildtools, no change: cold, warm, cold", r, t)
    assert r.same_commit.duplicate.n == 0 and t.n == 199
    assert e.n == t.n
    assert_in_delta e.ms, t.ms, t.n
  end

  test "abseil, header change: cold, cold at the new commit, then warm (constructed)", %{ctx: ctx} do
    {r, t} =
      run(ctx, [
        {"abseil_a1", 0, "c1"},
        {"abseil_b2", 900, "c2"},
        {"abseil_b2", 1800, "c2", {:warm, "abseil_a1", 0}}
      ])

    e = line("abseil, header change: cold, cold, warm*", r, t)
    assert r.hits.n == 387 and t.n == 622
    # Per kind of action the share is exact here (both builds ran the same actions);
    # what is left is rounding and the difference between the two machines' times.
    assert_in_delta e.n, t.n, 3
    assert_in_delta e.ms, t.ms, t.ms * 0.02
  end

  test "abseil, header change: cold, warm (constructed), then cold at the new commit", %{ctx: ctx} do
    {r, t} =
      run(ctx, [
        {"abseil_a1", 0, "c1"},
        {"abseil_b2", 900, "c2", {:warm, "abseil_a1", 0}},
        {"abseil_b2", 1800, "c2"}
      ])

    e = line("abseil, header change: cold, warm*, cold", r, t)
    # The warm build settles the changed actions (duplicates at one commit); the share is
    # then applied to actions that are all unchanged: the estimate is low, inside the bracket.
    assert t.n == 622
    between!(r.same_commit.duplicate.n + 1, e.n, t.n - 1)
  end
end
