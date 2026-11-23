defmodule Conveyor.Rbe.StreamPropertyTest do
  @moduledoc """
  The exactness claim of the stream variant (PLAN §28) as a property: for any
  executions of a few keys spread over builds of two projects of one cache group, in two
  hours, at two commits or none, with keys merged in any order, hours read between any two merges and
  one build merged twice, what the hourly rows hold equals the brute-force
  classification, in both key spaces: nothing is left stale by a late arrival.
  """
  use Conveyor.DataCase, async: false
  use ExUnitProperties

  alias Conveyor.ExecLog.ActionKey
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.Scope
  alias Conveyor.Projects
  alias Conveyor.Rbe.{Groups, Report, Settings, Stream, StreamActions, StreamChunk}

  defp t0 do
    at = DateTime.add(DateTime.utc_now(), -4 * 3600, :second)
    %{at | minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp builds do
    execution = tuple({integer(1..3), integer(0..4000), integer(1..2000)})

    list_of(
      tuple(
        {integer(0..1), member_of([nil, "c1", "c2"]), member_of([0, 2, 3700]),
         list_of(execution, min_length: 1, max_length: 4)}
      ),
      min_length: 2,
      max_length: 5
    )
  end

  defp insert!(project, commit, offset_s, executions, t0) do
    t0 = DateTime.add(t0, offset_s, :second)
    us = DateTime.to_unix(t0, :microsecond)

    records =
      for {{key, start_ms, duration_ms}, i} <- Enum.with_index(executions, 1) do
        StreamActions.record(
          "//pkg:t#{key}",
          "Compile",
          "out/#{key}",
          ["cc", "#{key}"],
          us + start_ms * 1000,
          us + (start_ms + duration_ms) * 1000,
          us,
          2 * i
        )
      end

    inv =
      Repo.insert!(%Invocation{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        status: "succeeded",
        tags: if(commit, do: %{"commit" => commit}, else: %{}),
        inserted_at: t0,
        updated_at: t0,
        started_at: t0,
        last_event_at: t0,
        finished_at: DateTime.add(t0, 10, :second),
        stream_actions: length(records)
      })

    # Two chunks when there is more than one record: the merge makes them one.
    records
    |> Enum.chunk_every(max(div(length(records), 2), 1))
    |> Enum.each(fn chunk ->
      Repo.insert!(%StreamChunk{
        invocation_id: inv.id,
        first_seq: elem(hd(chunk), 6),
        day: DateTime.to_date(t0),
        n: length(chunk),
        records: StreamActions.encode(chunk)
      })
    end)

    {inv, records}
  end

  # The first execution of each key among `stored`, as the row of the key would say it.
  defp firsts(stored, key_of) do
    for({inv, records} <- stored, r <- records, key = key_of.(inv, r), do: {key, inv, r})
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {key, execs} ->
      {_, inv, {_, start, duration, _, _, _, seq}} =
        Enum.min_by(execs, fn {_, inv, {_, start, duration, _, _, _, seq}} ->
          {start + duration, start, inv.id, seq}
        end)

      {key,
       %{
         first_invocation_id: inv.id,
         first_ordinal: seq,
         first_finish: DateTime.from_unix!(start + duration, :microsecond)
       }}
    end)
  end

  # `class → {count, ms}` of a project's executions, by brute force over everything stored.
  defp brute(stored, project, key_of) do
    wide = firsts(stored, key_of)
    own = stored |> Enum.filter(fn {inv, _} -> inv.project_id == project.id end) |> firsts(key_of)

    for {inv, records} <- stored, inv.project_id == project.id, r <- records, reduce: %{} do
      acc ->
        {_, start, duration, _, _, _, seq} = r
        spawn = %{ordinal: seq, started_at: DateTime.from_unix!(start, :microsecond)}

        class =
          case key_of.(inv, r) do
            nil -> :no_commit
            key -> ActionKey.classify(spawn, inv.id, own[key], wide[key])
          end

        Map.update(acc, class, {1, div(duration, 1000)}, fn {n, ms} ->
          {n + 1, ms + div(duration, 1000)}
        end)
    end
  end

  defp stored(figure) do
    cross = figure.cross_project

    %{
      first: figure.first,
      no_commit: figure.no_commit,
      # `racing` and `sequential` include the cross-project ones; together they are all
      # the duplicates, which is what is compared.
      duplicate: figure.duplicate,
      cross: cross
    }
    |> Map.new(fn {k, c} -> {k, {c.n, c.ms}} end)
  end

  defp expected(classes) do
    get = fn names ->
      names
      |> Enum.map(&Map.get(classes, &1, {0, 0}))
      |> Enum.reduce({0, 0}, fn {n, ms}, {an, ams} -> {an + n, ams + ms} end)
    end

    %{
      first: get.([:first]),
      no_commit: get.([:no_commit]),
      duplicate: get.([:racing, :racing_cross, :sequential, :sequential_cross]),
      cross: get.([:racing_cross, :sequential_cross])
    }
  end

  property "any arrival order: the stored figures are the brute-force classification" do
    default = Projects.ensure_default_project!()
    {:ok, default} = Groups.put(default, "stream-prop")
    {:ok, other} = Projects.create_project(%{slug: "stream-prop-other", name: "Other"})
    {:ok, other} = Groups.put(other, "stream-prop")
    projects = [default, other]

    check all(
            builds <- builds(),
            order <-
              builds
              |> length()
              |> then(&Enum.to_list(0..(&1 - 1)))
              |> StreamData.constant()
              |> StreamData.map(&Enum.shuffle/1),
            again <- integer(0..(length(builds) - 1)),
            max_runs: 25
          ) do
      Repo.delete_all(StreamChunk)
      Repo.delete_all(ActionKey)
      Repo.delete_all(Conveyor.Metrics.Rollup.Row)
      Repo.delete_all(Invocation)
      t0 = t0()

      stored =
        for {project, commit, offset, executions} <- builds,
            do: insert!(Enum.at(projects, project), commit, offset, executions, t0)

      scope = %Scope{from: DateTime.add(t0, -3600, :second), to: DateTime.add(t0, 7200, :second)}

      read = fn p ->
        Report.build(%{scope | project_id: p.id}, settings: Settings.get(p)).stream
      end

      # Keys are merged in the drawn order; the hours are read (and stored) in between.
      for i <- order ++ [again] do
        {inv, _} = Enum.at(stored, i)
        assert :ok = Stream.merge_keys!(Repo.get!(Invocation, inv.id))
        Enum.each(projects, read)
        # A rollup stamps its row five seconds back, so in a test every row would be
        # stale anyway: the rows are stamped now, and only a touch after this makes an
        # hour be computed again.
        Repo.update_all(Conveyor.Metrics.Rollup.Row, set: [updated_at: DateTime.utc_now()])
      end

      for p <- projects, Enum.any?(stored, fn {inv, _} -> inv.project_id == p.id end) do
        report = read.(p)
        any = brute(stored, p, fn _inv, r -> elem(r, 0) end)

        same =
          brute(stored, p, fn inv, r ->
            commit = Stream.commit(inv.tags)
            commit && Stream.commit_key(elem(r, 0), commit)
          end)

        assert stored(report.any_commit) == expected(any)
        assert stored(report.same_commit) == expected(same)
        assert report.pending_builds == 0
      end
    end
  end
end
