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

    # A project with its own, shorter retention loses a 10-day-old build; the default
    # project keeps its 1-day-old one.
    {:ok, short} = Projects.create_project(%{slug: "short-lived", name: "Short"})
    {:ok, short} = Projects.put_storage(short, %{"retention_days" => "7"})
    assert Projects.retention_days(short) == 7

    short_old =
      Repo.insert!(%Invocation{
        id: Conveyor.Bep.Replay.uuid(),
        project_id: short.id,
        started_at: DateTime.add(now, -10, :day)
      })

    short_new =
      Repo.insert!(%Invocation{
        id: Conveyor.Bep.Replay.uuid(),
        project_id: short.id,
        started_at: DateTime.add(now, -3, :day)
      })

    assert {:ok, %{deleted: 3, projects: per_project}} = BuildRetention.perform(%Oban.Job{})
    assert per_project["default"].deleted == 2 and per_project["short-lived"].deleted == 1

    assert Repo.get(Invocation, old.id) == nil and Repo.get(Invocation, no_start.id) == nil
    assert Repo.get(Invocation, recent.id) != nil and Repo.get(Invocation, short_new.id) != nil
    assert Repo.get(Invocation, short_old.id) == nil
    assert Repo.all(from t in Target, select: t.label) == ["//b"]
    assert [%{value: "new", count: 1}] = Repo.all(from t in TagKey, where: t.key == "team")

    # Nothing left to delete: no facet rebuild, no error.
    assert {:ok, %{deleted: 0}} = BuildRetention.perform(%Oban.Job{})

    # Settings validation.
    assert {:error, msg} = Projects.put_storage(short, %{"retention_days" => "0"})
    assert msg =~ "days"
    assert {:error, msg} = Projects.put_storage(short, %{"blob_prefix" => "Bad Prefix"})
    assert msg =~ "prefix"

    assert {:ok, short} =
             Projects.put_storage(short, %{"retention_days" => "", "blob_prefix" => ""})

    assert Projects.retention_days(short) == nil and Projects.blob_prefix(short) == "short-lived"
    assert Projects.blob_prefix(short.id) == "short-lived"
  end
end
