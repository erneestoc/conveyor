defmodule Conveyor.Bep.ReplayTest do
  use Conveyor.GrpcCase, async: false

  alias Conveyor.Bep.Replay

  @tag :capture_log
  test "can skip lifecycle events and honours a fixed invocation id", %{grpc_port: port} do
    id = Replay.uuid()

    assert {:ok, %{invocation_id: ^id, acks: acks, sent: sent}} =
             Replay.run(fixture("analysis_failure"),
               port: port,
               lifecycle: false,
               invocation_id: id,
               delay_ms: 1
             )

    assert acks == Enum.to_list(1..sent)
  end

  @tag :capture_log
  test "returns an error when the server is unreachable" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed_port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:error, _} = Replay.run(fixture("analysis_failure"), port: closed_port)

    assert {:error, _} =
             Replay.run(fixture("analysis_failure"), port: closed_port, lifecycle: false)
  end

  test "generates RFC 4122 version 4 uuids" do
    assert Replay.uuid() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert Replay.uuid() != Replay.uuid()
  end
end
