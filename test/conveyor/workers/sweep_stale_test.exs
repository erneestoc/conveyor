defmodule Conveyor.Workers.SweepStaleTest do
  use Conveyor.DataCase, async: true
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.Invocations.Invocation
  alias Conveyor.Workers.SweepStale

  setup do
    %{project: Conveyor.Projects.ensure_default_project!()}
  end

  defp build(project, status, updated_ago_s, extra \\ []) do
    now = DateTime.utc_now()
    at = DateTime.add(now, -updated_ago_s, :second)

    Repo.insert!(
      struct(
        %Invocation{
          id: Conveyor.Bep.Replay.uuid(),
          project_id: project.id,
          status: status,
          started_at: DateTime.add(at, -90, :second),
          last_event_at: at,
          inserted_at: at,
          updated_at: at
        },
        extra
      )
    )
  end

  test "marks builds nobody streams any more disconnected", %{project: project} do
    dead = build(project, "in_progress", 3 * 3600)
    quiet = build(project, "in_progress", 60)
    done = build(project, "succeeded", 3 * 3600, finished_at: DateTime.utc_now())

    assert {:ok, %{swept: 1}} = perform_job(SweepStale, %{})

    swept = Repo.get!(Invocation, dead.id)
    assert swept.status == "disconnected"
    assert swept.finished_at == dead.last_event_at
    assert swept.duration_ms == 90_000
    assert DateTime.compare(swept.updated_at, dead.updated_at) == :gt
    assert Repo.get!(Invocation, quiet.id).status == "in_progress"
    assert Repo.get!(Invocation, done.id) == done
    assert SweepStale.sweep() == 0
  end
end
