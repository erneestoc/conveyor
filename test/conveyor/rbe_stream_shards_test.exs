defmodule Conveyor.Rbe.StreamShardsTest do
  @moduledoc """
  Shards of one commit that start together against one cache (PLAN §28.7). A shard is
  served actions another shard ran *during* its own run: Bazel sends such a hit with the
  other execution's start and end, which lie after this build's start, so "started
  before its build" does not see it. The fixture is the two recorded abseil builds of
  one commit, 7 s apart, with every second action of the second build that the first
  one started after the second build began turned into such a hit (the first build's
  times, copied); the rest of the second build races or repeats for real. The truth is
  by construction.
  """
  use Conveyor.IngestCase, async: false

  alias Conveyor.Metrics.Scope
  alias Conveyor.Rbe.{Report, Settings, Stream}
  alias Conveyor.StreamFixture

  @moduletag :capture_log

  defp us(t), do: t.seconds * 1_000_000 + div(t.nanos, 1000)

  defp at(%{id: %{id: {:action_completed, aid}}, payload: {:action, a}}),
    do: {a.type, aid.label, aid.primary_output}

  defp timed(events) do
    for %{payload: {:action, %{success: true, start_time: %{} = s, end_time: %{} = e}}} = ev <-
          events,
        us(e) > us(s),
        into: %{},
        do: {at(ev), {us(s), us(e), ev}}
  end

  test "hits served during the build are hits; the rest is classed exactly", %{ctx: ctx} do
    base = DateTime.utc_now() |> DateTime.add(-4 * 3600, :second)
    base = %{base | minute: 0, second: 0, microsecond: {0, 6}}

    shift =
      &DateTime.diff(DateTime.add(base, &2, :second), StreamFixture.started_at(&1), :microsecond)

    tags = %{"commit" => "c1"}
    first = StreamFixture.events("abseil_a1", shift_us: shift.("abseil_a1", 0), tags: tags)
    second = StreamFixture.events("abseil_b1", shift_us: shift.("abseil_b1", 7), tags: tags)
    second_start = DateTime.to_unix(DateTime.add(base, 7, :second), :microsecond)
    ran = timed(first)

    served =
      second
      |> timed()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.filter(&(ran[&1] && elem(ran[&1], 0) > second_start))
      |> Enum.take_every(2)
      |> MapSet.new()

    assert MapSet.size(served) > 100

    second =
      Enum.map(second, fn
        %{payload: {:action, a}} = ev ->
          with true <- MapSet.member?(served, at(ev)),
               {_, _, %{payload: {:action, o}}} <- ran[at(ev)] do
            %{ev | payload: {:action, %{a | start_time: o.start_time, end_time: o.end_time}}}
          else
            _ -> ev
          end

        ev ->
          ev
      end)

    # The truth: the second build's other executions against the first build's.
    theirs = for {k, {s, e, _}} <- timed(second), not MapSet.member?(served, k), do: {k, s, e}

    {racing, sequential, firsts} =
      Enum.reduce(theirs, {[], [], 0}, fn {k, s, e}, {r, q, f} ->
        {s1, e1, _} = ran[k]

        cond do
          # the second build finished it first: the first build's execution is the repeat
          {e, s} < {e1, s1} and s1 < e -> {[e1 - s1 | r], q, f + 1}
          {e, s} < {e1, s1} -> {r, [e1 - s1 | q], f + 1}
          s < e1 -> {[e - s | r], q, f}
          true -> {r, [e - s | q], f}
        end
      end)

    assert firsts >= 0
    StreamFixture.ingest!(ctx, first)
    StreamFixture.ingest!(ctx, second)
    assert Stream.merge_pending!(DateTime.add(base, -3600, :second)) == 2

    scope = %Scope{
      from: DateTime.add(base, -3600, :second),
      to: DateTime.add(base, 4 * 3600, :second),
      project_id: ctx.project_id
    }

    r =
      Report.build(scope, settings: Settings.get(Conveyor.Projects.get_project!(ctx.project_id))).stream

    IO.puts(
      "shards | served during the build #{MapSet.size(served)} | executed #{r.executed.n} hits #{r.hits.n}" <>
        " | racing #{r.same_commit.racing.n} (truth #{length(racing)}) sequential #{r.same_commit.sequential.n} (truth #{length(sequential)})"
    )

    assert r.hits.n == MapSet.size(served)
    assert r.executed.n == map_size(ran) + length(theirs)
    assert r.same_commit.first.n == map_size(ran)

    for figure <- [r.same_commit, r.any_commit] do
      assert figure.racing.n == length(racing)
      assert figure.sequential.n == length(sequential)
      assert_in_delta figure.racing.ms, div(Enum.sum(racing), 1000), length(racing) + 1

      assert_in_delta figure.sequential.ms,
                      div(Enum.sum(sequential), 1000),
                      length(sequential) + 1
    end

    assert r.hit_rate.today == MapSet.size(served) / (r.hits.n + r.executed.n)
  end
end
