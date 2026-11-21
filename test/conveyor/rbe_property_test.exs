defmodule Conveyor.RbePropertyTest do
  @moduledoc """
  The exactness claim of PLAN §27 as a property: for any executions of a few keys spread
  over builds of two projects of one cache group, stored in any order (with one build
  stored twice), the key rows are the minimum of the executions' order in each scope and
  the report's classes are the definition's, so wasted time is the total minus the time
  of each key's earliest finisher.
  """
  use Conveyor.DataCase, async: false
  use ExUnitProperties

  alias Conveyor.{ExecLog, Projects}
  alias Conveyor.ExecLog.{ActionKey, Spawn}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.Scope
  alias Conveyor.Rbe.{Groups, Report, Settings}

  @t0 ~U[2026-11-20 10:00:00.000000Z]

  defp spawn(key, start_ms, duration_ms, output) do
    %{
      target_label: "//pkg:t#{key}",
      mnemonic: "Compile",
      primary_output: "out/#{key}",
      cache_hit: false,
      runner: "linux-sandbox",
      exit_code: 0,
      status: nil,
      remotable: true,
      cacheable: true,
      remote_cacheable: true,
      total_ms: duration_ms,
      exec_ms: duration_ms,
      queue_ms: nil,
      upload_ms: nil,
      fetch_ms: nil,
      setup_ms: nil,
      network_ms: nil,
      input_files: 1,
      input_bytes: 1,
      output_bytes: 1,
      inputs_digest: String.duplicate("a", 64),
      outputs_digest: String.duplicate(Integer.to_string(output), 64),
      outputs: %{},
      inputs_list: "",
      action_key: :crypto.hash(:sha256, "key #{key}"),
      key_source: 1,
      started_at: DateTime.add(@t0, start_ms, :millisecond),
      platform_cores: nil
    }
  end

  defp builds do
    execution = tuple({integer(1..3), integer(0..4000), integer(1..2000), integer(1..2)})

    list_of(tuple({integer(0..1), list_of(execution, min_length: 1, max_length: 4)}),
      min_length: 2,
      max_length: 5
    )
  end

  property "key rows and classes do not depend on the order of arrival" do
    default = Projects.ensure_default_project!()
    {:ok, default} = Groups.put(default, "prop")
    {:ok, other} = Projects.create_project(%{slug: "prop-other", name: "Other"})
    {:ok, other} = Groups.put(other, "prop")
    projects = [default, other]
    group = Groups.of(default)

    check all(specs <- builds(), seed <- integer(), max_runs: 30) do
      Repo.delete_all(Invocation)
      Repo.delete_all(ActionKey)

      stored =
        for {project_index, executions} <- specs do
          project = Enum.at(projects, project_index)

          inv =
            Repo.insert!(%Invocation{
              id: Ecto.UUID.generate(),
              project_id: project.id,
              status: "succeeded",
              tags: %{},
              inserted_at: @t0,
              updated_at: @t0,
              started_at: @t0
            })

          spawns =
            executions
            |> Enum.with_index()
            |> Enum.map(fn {{key, start, duration, output}, ordinal} ->
              key |> spawn(start, duration, output) |> Map.put(:ordinal, ordinal)
            end)

          {inv, spawns}
        end

      :rand.seed(:exsss, {seed, seed, seed})
      order = Enum.shuffle(stored) ++ [Enum.random(stored)]
      for {inv, spawns} <- order, do: ExecLog.store!(inv, %{spawns: spawns})

      # the definition, computed from the executions themselves
      all = for {inv, spawns} <- stored, s <- spawns, do: {inv, s}

      model = fn members ->
        all
        |> Enum.filter(fn {inv, _} -> inv.project_id in members end)
        |> Enum.group_by(fn {_, s} -> s.action_key end)
        |> Map.new(fn {key, execs} ->
          {inv, first} = Enum.min_by(execs, fn {inv, s} -> ActionKey.rank(s, inv.id) end)

          {key,
           %{
             first_invocation_id: inv.id,
             first_ordinal: first.ordinal,
             first_finish: ActionKey.finish(first),
             multi:
               execs |> Enum.map(fn {i, _} -> i.project_id end) |> Enum.uniq() |> length() > 1,
             nondet:
               execs |> Enum.map(fn {_, s} -> s.outputs_digest end) |> Enum.uniq() |> length() > 1
           }}
        end)
      end

      scopes = %{
        default.id => model.([default.id]),
        other.id => model.([other.id]),
        -group.id => model.([default.id, other.id])
      }

      for {scope, expected} <- scopes do
        rows = Repo.all(from k in ActionKey, where: k.scope == ^scope)
        assert length(rows) == map_size(expected)

        for row <- rows do
          assert Map.take(row, [
                   :first_invocation_id,
                   :first_ordinal,
                   :first_finish,
                   :multi,
                   :nondet
                 ]) ==
                   expected[row.key]
        end
      end

      classes =
        Enum.group_by(
          all,
          fn {inv, s} ->
            ActionKey.classify(
              s,
              inv.id,
              scopes[inv.project_id][s.action_key],
              scopes[-group.id][s.action_key]
            )
          end,
          fn {_, s} -> s.exec_ms end
        )

      ms = fn class -> classes |> Map.get(class, []) |> Enum.sum() end

      report =
        Report.build(
          %Scope{
            project_ids: [default.id, other.id],
            from: DateTime.add(@t0, -60),
            to: DateTime.add(@t0, 600)
          },
          settings: Settings.get(default)
        )

      total = all |> Enum.map(fn {_, s} -> s.exec_ms end) |> Enum.sum()
      assert report.executed.ms == total
      assert report.racing.total.ms == ms.(:racing) + ms.(:racing_cross)
      assert report.racing.cross_project.ms == ms.(:racing_cross)
      assert report.cache.same_project.ms == ms.(:sequential)
      assert report.cache.cross_project.ms == ms.(:sequential_cross)
      # wasted = everything executed minus the earliest finisher of each key
      assert report.racing.total.ms + report.cache.gap.ms == total - ms.(:first)
      assert length(Map.get(classes, :first, [])) == map_size(scopes[-group.id])
      assert Repo.aggregate(Spawn, :count) == length(all)
    end
  end
end
