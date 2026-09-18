defmodule Conveyor.InvocationsTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Invocations
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Projects
  alias Conveyor.Repo

  setup do
    project = Projects.ensure_default_project!()
    now = DateTime.utc_now()

    ids =
      for i <- 1..3 do
        id = Conveyor.Bep.Replay.uuid()

        Repo.insert!(%Invocation{
          id: id,
          project_id: project.id,
          status: if(i == 2, do: "failed", else: "succeeded"),
          started_at: DateTime.add(now, -i, :minute)
        })

        id
      end

    %{project: project, ids: ids}
  end

  test "get and list with filters and cursor", %{project: project, ids: [newest, middle, oldest]} do
    assert Invocations.get(newest).id == newest
    assert Invocations.get("not-a-uuid") == nil
    assert Invocations.get!(newest).id == newest

    assert Enum.map(Invocations.list(project_id: project.id), & &1.id) == [newest, middle, oldest]
    assert Enum.map(Invocations.list(status: "failed"), & &1.id) == [middle]

    assert [%{id: ^middle}] =
             Invocations.list(
               project_id: project.id,
               limit: 1,
               before: {Invocations.get(newest).started_at, newest}
             )

    assert Invocations.list(project_id: -1) == []
  end

  test "day falls back sensibly and empty invocations read as empty" do
    inv = %Invocation{
      id: Conveyor.Bep.Replay.uuid(),
      started_at: nil,
      inserted_at: ~U[2026-01-02 03:04:05Z]
    }

    assert Invocations.day(inv) == ~D[2026-01-02]
    assert Invocations.day(%Invocation{}) == Date.utc_today()
    inv = Repo.insert!(%Invocation{id: inv.id, project_id: Projects.ensure_default_project!().id})

    assert Invocations.events(inv) == [] and Invocations.log(inv) == "" and
             Invocations.log_segments(inv) == []

    assert Invocations.targets(inv.id) == [] and Invocations.test_results(inv.id) == [] and
             Invocations.actions(inv.id) == []

    assert Invocations.metrics(inv.id) == nil and Invocations.named_sets(inv.id) == %{}
    assert Invocation.statuses() |> length() == 6
  end
end
