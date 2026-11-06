defmodule Conveyor.RawLogModeTest do
  use Conveyor.IngestCase, async: false

  alias Conveyor.{Invocations, Projects, RawLog}
  alias Conveyor.Bep.Replay
  alias Conveyor.Invocations.{EventSegment, LogSegment}
  import Ecto.Query

  setup %{project: project} do
    {:ok, _key, key} = Projects.create_api_key(project, %{name: "rawlog"})
    previous = Application.get_env(:conveyor, RawLog)
    on_exit(fn -> Application.put_env(:conveyor, RawLog, previous) end)
    %{key: key}
  end

  defp ingest!(port, key, fixture) do
    {:ok, %{invocation_id: id, sent: sent}} =
      Replay.run(fixture(fixture), port: port, api_key: key)

    :ok = await_worker_exit(id)
    assert :ok = Conveyor.Ingest.Verify.check(id, sent - 1)
    Invocations.get!(id)
  end

  test "blob mode stores bytes in objects and reads them back identically", %{
    grpc_port: port,
    key: key
  } do
    Application.put_env(:conveyor, RawLog, mode: :postgres, flush_ms: 20)
    reference = ingest!(port, key, "clean_build_and_test")

    Application.put_env(:conveyor, RawLog, mode: :blob, flush_ms: 20)
    assert RawLog.blob_mode?()
    inv = ingest!(port, key, "clean_build_and_test")

    rows = Repo.all(from(s in EventSegment, where: s.invocation_id == ^inv.id))

    assert rows != [] and
             Enum.all?(
               rows,
               &(is_nil(&1.payload) and is_binary(&1.object_key) and &1.object_length > 0)
             )

    logs = Repo.all(from(s in LogSegment, where: s.invocation_id == ^inv.id))
    assert logs != [] and Enum.all?(logs, &is_nil(&1.data))

    assert Invocations.events(inv) |> Enum.map(& &1.id) ==
             Invocations.events(reference) |> Enum.map(& &1.id)

    assert Invocations.log(inv) == Invocations.log(reference)
    assert length(Invocations.raw_frames(inv)) == length(Invocations.raw_frames(reference))

    # The object is the only copy: once swept, the build's raw data is gone.
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) >= 1
    assert_raise RuntimeError, ~r/raw log/, fn -> Invocations.log(inv) end
  end
end
