defmodule Conveyor.Grpc.DrainTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Bep.Replay
  alias Conveyor.{Drain, Projects}

  test "a draining node refuses new streams but still answers lifecycle events", %{
    project: project,
    grpc_port: port
  } do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "drain"})
    Drain.start()
    on_exit(fn -> Drain.stop() end)

    assert {:error, {:stream_closed, _}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    Drain.stop()

    assert {:ok, %{invocation_id: id}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    :ok = await_worker_exit(id)
  end
end
