defmodule Conveyor.Bep.ReplayTest do
  use Conveyor.IngestCase, async: false

  alias Conveyor.Bep.Replay
  alias Conveyor.Projects

  setup %{project: project} do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "test"})
    %{key: plaintext}
  end

  @tag :capture_log
  test "can skip lifecycle events and honours a fixed invocation id", %{grpc_port: port, key: key} do
    id = Replay.uuid()

    assert {:ok, %{invocation_id: ^id, acks: acks, sent: sent}} =
             Replay.run(fixture("analysis_failure"),
               port: port,
               api_key: key,
               lifecycle: false,
               invocation_id: id,
               delay_ms: 1
             )

    assert acks == Enum.to_list(1..sent)
  end

  @tag :capture_log
  test "returns an error when the server is unreachable or rejects the stream", %{grpc_port: port} do
    closed_port = Conveyor.GrpcCase.free_port()
    assert {:error, _} = Replay.run(fixture("analysis_failure"), port: closed_port)

    assert {:error, _} =
             Replay.run(fixture("analysis_failure"), port: closed_port, lifecycle: false)

    assert {:error, _} =
             Replay.run(fixture("analysis_failure"),
               port: port,
               api_key: "conveyor_bad_key",
               lifecycle: false
             )
  end

  test "generates RFC 4122 version 4 uuids" do
    assert Replay.uuid() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert Replay.uuid() != Replay.uuid()
  end
end
