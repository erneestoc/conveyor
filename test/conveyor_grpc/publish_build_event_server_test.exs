defmodule Conveyor.Grpc.PublishBuildEventServerTest do
  use Conveyor.GrpcCase, async: false

  alias Conveyor.Bep.Replay

  @tag :capture_log
  test "acks every event of a replayed build in order", %{grpc_port: port} do
    assert {:ok, result} =
             Replay.run(fixture("clean_build_and_test"), port: port, api_key: "test-key")

    assert result.acks == Enum.to_list(1..result.sent)
  end

  @tag :capture_log
  test "handles several concurrent streams", %{grpc_port: port} do
    results =
      ~w(build_failure test_failure flaky_test cached_build_and_test)
      |> Task.async_stream(&Replay.run(fixture(&1), port: port), timeout: 30_000)
      |> Enum.map(fn {:ok, r} -> r end)

    assert length(results) == 4

    for result <- results do
      assert {:ok, %{acks: acks, sent: sent}} = result
      assert acks == Enum.to_list(1..sent)
    end
  end
end
