defmodule Conveyor.Workers.BuildRetentionTest do
  use Conveyor.DataCase, async: false

  import Ecto.Query

  alias Conveyor.Invocations.{Invocation, TagKey, Target}
  alias Conveyor.Projects
  alias Conveyor.Repo
  alias Conveyor.Workers.BuildRetention

  test "deletes builds older than the retention window with their rows and rebuilds facets" do
    project = Projects.ensure_default_project!()
    now = DateTime.utc_now()

    insert = fn started, tags ->
      Repo.insert!(%Invocation{
        id: Conveyor.Bep.Replay.uuid(),
        project_id: project.id,
        started_at: started,
        tags: tags
      })
    end

    old = insert.(DateTime.add(now, -100, :day), %{"team" => "old"})
    no_start = Repo.insert!(%Invocation{id: Conveyor.Bep.Replay.uuid(), project_id: project.id})

    Repo.update_all(from(i in Invocation, where: i.id == ^no_start.id),
      set: [inserted_at: DateTime.add(now, -200, :day)]
    )

    recent = insert.(DateTime.add(now, -1, :day), %{"team" => "new"})
    Repo.insert!(%Target{invocation_id: old.id, label: "//a", aspect: "", status: "failed"})
    Repo.insert!(%Target{invocation_id: recent.id, label: "//b", aspect: "", status: "success"})

    assert {:ok, %{deleted: 2}} = BuildRetention.perform(%Oban.Job{})

    assert Repo.get(Invocation, old.id) == nil and Repo.get(Invocation, no_start.id) == nil
    assert Repo.get(Invocation, recent.id)
    assert Repo.all(from t in Target, select: t.label) == ["//b"]
    assert [%{value: "new", count: 1}] = Repo.all(from t in TagKey, where: t.key == "team")

    # Nothing left to delete: no facet rebuild, no error.
    assert {:ok, %{deleted: 0}} = BuildRetention.perform(%Oban.Job{})
  end
end
