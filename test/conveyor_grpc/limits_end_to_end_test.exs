defmodule Conveyor.Grpc.LimitsEndToEndTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.{Invocations, Limits, Projects}
  alias Google.Devtools.Build.V1, as: V1
  alias Google.Devtools.Build.V1.PublishBuildEvent.Stub

  setup do
    Limits.reset()
    :ok
  end

  defp open_stream(port, key) do
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)
    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => key})
    {channel, stream}
  end

  test "a key at its stream limit is refused until a stream ends", %{
    project: project,
    grpc_port: port
  } do
    {:ok, key, plaintext} =
      Projects.create_api_key(project, %{name: "one", limits: %{"max_streams" => 1}})

    assert key.limits == %{"max_streams" => 1}
    events = Fixture.read!(fixture("analysis_failure"))

    {ch1, s1} = open_stream(port, plaintext)
    sid1 = %V1.StreamId{build_id: "b", invocation_id: Replay.uuid(), component: :TOOL}

    GRPC.Stub.send_request(s1, %V1.PublishBuildToolEventStreamRequest{
      ordered_build_event: Replay.ordered_event(sid1, 1, hd(events))
    })

    {:ok, replies} = GRPC.Stub.recv(s1)
    assert {:ok, %{sequence_number: 1}} = Enum.at(replies, 0)
    assert Limits.streams(key.id) == 1

    {ch2, s2} = open_stream(port, plaintext)
    sid2 = %V1.StreamId{build_id: "b", invocation_id: Replay.uuid(), component: :TOOL}

    GRPC.Stub.send_request(
      s2,
      %V1.PublishBuildToolEventStreamRequest{
        ordered_build_event: Replay.ordered_event(sid2, 1, hd(events))
      },
      end_stream: true
    )

    assert {:error, %GRPC.RPCError{status: 8, message: "too many" <> _}} = GRPC.Stub.recv(s2)
    GRPC.Stub.disconnect(ch2)

    GRPC.Stub.cancel(s1)
    GRPC.Stub.disconnect(ch1)
    wait_until(fn -> Limits.streams(key.id) == 0 end)

    assert {:ok, %{sent: sent, acks: acks}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    assert length(acks) == sent
  end

  test "events beyond the rate limit are slowed down, not failed", %{
    project: project,
    grpc_port: port
  } do
    {:ok, _key, plaintext} =
      Projects.create_api_key(project, %{name: "slow", limits: %{"max_events_per_second" => 20}})

    {elapsed_us, result} =
      :timer.tc(fn ->
        Replay.run(fixture("clean_build_and_test"), port: port, api_key: plaintext)
      end)

    assert {:ok, %{sent: sent, acks: acks}} = result
    assert length(acks) == sent
    # ~98 events at 20/s after the first 20 free tokens: several seconds.
    assert elapsed_us >= 2_000_000
  end

  test "the build log is capped per invocation", %{project: project, grpc_port: port} do
    {:ok, _key, plaintext} =
      Projects.create_api_key(project, %{name: "small", limits: %{"max_log_bytes" => 200}})

    assert {:ok, r} = Replay.run(fixture("clean_build_and_test"), port: port, api_key: plaintext)
    :ok = await_worker_exit(r.invocation_id)
    inv = Invocations.get!(r.invocation_id)
    log = Invocations.log(inv)
    assert log =~ "build log truncated at 200 bytes"
    assert inv.log_bytes < 400
    assert inv.event_count == r.sent - 1
  end

  test "invalid limits are rejected", %{project: project} do
    assert {:error, changeset} =
             Projects.create_api_key(project, %{name: "bad", limits: %{"max_streams" => -1}})

    assert "keys must be" <> _ = hd(errors_on(changeset).limits)
    {:ok, key, _} = Projects.create_api_key(project, %{name: "ok"})
    assert {:ok, key} = Projects.update_api_key_limits(key, %{"max_log_bytes" => 1024})
    assert Limits.for_key(key).max_log_bytes == 1024
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
