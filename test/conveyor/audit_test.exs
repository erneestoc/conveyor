defmodule Conveyor.AuditTest do
  use Conveyor.DataCase, async: true

  alias Conveyor.Accounts.Scope
  alias Conveyor.Audit
  alias Conveyor.Projects

  test "records actors of every kind and lists recent entries" do
    project = Projects.ensure_default_project!()
    {:ok, key, _} = Projects.create_api_key(project, %{name: "ci"})

    :ok = Audit.log("system", "test.system")

    :ok =
      Audit.log(%Scope{admin_session?: true, admin?: true}, "test.admin",
        subject: {"project", project.id},
        project_id: project.id
      )

    :ok = Audit.log(%Scope{}, "test.anon")
    :ok = Audit.log(key, "test.key", metadata: %{"a" => 1}, ip: "127.0.0.1")
    user = %Conveyor.Accounts.User{email: "u@example.com"}
    :ok = Audit.log(%Scope{user: user}, "test.user", subject: {"user", 7})

    entries = Audit.recent(10)

    assert Enum.map(entries, & &1.action) |> Enum.take(5) ==
             ~w(test.user test.key test.anon test.admin test.system)

    assert %{actor: "u@example.com", actor_type: "user", subject_type: "user", subject_id: "7"} =
             hd(entries)

    assert %{actor: "ci (" <> _, actor_type: "api_key", metadata: %{"a" => 1}, ip: "127.0.0.1"} =
             Enum.at(entries, 1)

    assert %{actor: "anonymous", actor_type: "anonymous"} = Enum.at(entries, 2)

    assert %{actor: "admin-token", actor_type: "admin_token", project_id: pid} =
             Enum.at(entries, 3)

    assert pid == project.id
    assert %{actor: "system", actor_type: "system"} = Enum.at(entries, 4)
    assert [%{action: "test.admin"}] = Audit.recent(10, project_id: project.id)
  end

  @tag :capture_log
  test "never raises" do
    assert :ok = Audit.log("system", "bad", project_id: -1)
    assert Audit.ip(%Plug.Conn{remote_ip: {10, 0, 0, 1}}) == "10.0.0.1"
  end
end
