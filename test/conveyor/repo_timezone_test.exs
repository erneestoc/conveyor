defmodule Conveyor.RepoTimezoneTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.{ExecLog, ExecLogBuilder, Projects, Repo}
  alias Conveyor.Invocations.Invocation

  test "sessions run in UTC whatever the server's default is" do
    assert %{rows: [["UTC"]]} = Repo.query!("SHOW timezone")
  end

  test "the first execution of a key is stored at its own time under any session time zone" do
    Repo.query!("SET LOCAL timezone = 'America/Hermosillo'")
    project = Projects.ensure_default_project!()
    start = DateTime.add(DateTime.utc_now(), -600, :second)

    inv =
      Repo.insert!(%Invocation{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        status: "succeeded",
        inserted_at: start,
        updated_at: start,
        started_at: start,
        finished_at: DateTime.add(start, 20, :second)
      })

    {:ok, parsed} = [id: inv.id, base: start] |> ExecLogBuilder.log() |> ExecLog.parse()
    ExecLog.store!(inv, parsed)

    assert %{rows: [[keys, 0]]} =
             Repo.query!("""
             SELECT count(*),
                    count(*) FILTER (WHERE k.first_start <> s.started_at
                      OR k.first_finish <> s.started_at + s.total_ms * interval '1 millisecond')
             FROM action_keys k
             JOIN spawns s ON s.invocation_id = k.first_invocation_id AND s.ordinal = k.first_ordinal
             """)

    assert keys > 0
  end
end
