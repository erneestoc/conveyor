defmodule Conveyor.Grpc.PublishBuildEventServerTest do
  use Conveyor.IngestCase, async: false

  alias Conveyor.Bep.Replay
  alias Conveyor.Projects
  alias Google.Devtools.Build.V1, as: V1
  alias Google.Devtools.Build.V1.PublishBuildEvent.Stub

  setup %{project: project} do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "test"})
    %{key: plaintext}
  end

  @tag :capture_log
  test "acks every event of a replayed build in order", %{grpc_port: port, key: key} do
    assert {:ok, result} = Replay.run(fixture("clean_build_and_test"), port: port, api_key: key)
    assert result.acks == Enum.to_list(1..result.sent)
  end

  @tag :capture_log
  test "handles several concurrent streams", %{grpc_port: port, key: key} do
    results =
      ~w(build_failure test_failure flaky_test cached_build_and_test)
      |> Task.async_stream(&Replay.run(fixture(&1), port: port, api_key: key), timeout: 30_000)
      |> Enum.map(fn {:ok, r} -> r end)

    assert length(results) == 4

    for result <- results do
      assert {:ok, %{acks: acks, sent: sent}} = result
      assert acks == Enum.to_list(1..sent)
    end
  end

  @tag :capture_log
  test "acks console output, unknown type urls and undecodable payloads instead of failing the stream",
       %{grpc_port: port, key: key} do
    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    stream_id = %V1.StreamId{build_id: "b", invocation_id: Replay.uuid(), component: :TOOL}

    events = [
      {:console_output,
       %V1.BuildEvent.ConsoleOutput{type: :STDERR, output: {:text_output, "hello"}}},
      {:bazel_event,
       %Google.Protobuf.Any{type_url: "type.googleapis.com/other.Thing", value: ""}},
      {:bazel_event,
       %Google.Protobuf.Any{
         type_url: "type.googleapis.com/build_event_stream.BuildEvent",
         value: <<0xFF, 0xFF, 0xFF>>
       }},
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}
    ]

    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => key})

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {payload, seq} ->
      req = %V1.PublishBuildToolEventStreamRequest{
        ordered_build_event: Replay.ordered_event(stream_id, seq, payload)
      }

      GRPC.Stub.send_request(stream, req, end_stream: seq == length(events))
    end)

    {:ok, replies} = GRPC.Stub.recv(stream)
    assert Enum.map(replies, fn {:ok, r} -> r.sequence_number end) == [1, 2, 3, 4]
    GRPC.Stub.disconnect(channel)
    assert :ok = await_worker_exit(stream_id.invocation_id)
  end

  @tag :capture_log
  test "a gap in sequence numbers fails the stream with FAILED_PRECONDITION", %{
    grpc_port: port,
    key: key
  } do
    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    stream_id = %V1.StreamId{build_id: "b", invocation_id: Replay.uuid(), component: :TOOL}
    [started | _] = Conveyor.Bep.Fixture.read!(fixture("analysis_failure"))
    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => key})

    GRPC.Stub.send_request(stream, %V1.PublishBuildToolEventStreamRequest{
      ordered_build_event: Replay.ordered_event(stream_id, 1, started)
    })

    GRPC.Stub.send_request(
      stream,
      %V1.PublishBuildToolEventStreamRequest{
        ordered_build_event: Replay.ordered_event(stream_id, 5, started)
      },
      end_stream: true
    )

    case GRPC.Stub.recv(stream) do
      {:ok, replies} ->
        assert Enum.any?(replies, &match?({:error, %GRPC.RPCError{status: 9}}, &1))

      {:error, error} ->
        assert %GRPC.RPCError{status: 9} = error
    end

    GRPC.Stub.disconnect(channel)
  end

  @tag :capture_log
  test "a key of another project gets NOT_FOUND for a build it does not own and writes nothing",
       %{grpc_port: port, key: key} do
    assert {:ok, %{invocation_id: id, sent: sent}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: key)

    assert :ok = await_worker_exit(id)
    # (A finish notification that raced the worker's exit may still touch the timestamps.)
    row = fn -> Map.drop(reload(id), [:last_event_at, :updated_at]) end
    before = row.()

    {:ok, other} = Projects.create_project(%{slug: "intruder", name: "Intruder"})
    {:ok, _key, intruder} = Projects.create_api_key(other, %{name: "intruder"})
    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    stream_id = %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}
    [started | _] = Conveyor.Bep.Fixture.read!(fixture("analysis_failure"))

    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => intruder})

    GRPC.Stub.send_request(
      stream,
      %V1.PublishBuildToolEventStreamRequest{
        ordered_build_event: Replay.ordered_event(stream_id, sent + 1, started)
      },
      end_stream: true
    )

    case GRPC.Stub.recv(stream) do
      {:ok, replies} -> assert [{:error, %GRPC.RPCError{status: 5}}] = Enum.to_list(replies)
      {:error, error} -> assert %GRPC.RPCError{status: 5} = error
    end

    attempt =
      {:invocation_attempt_started, %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 2}}

    assert {:error, %GRPC.RPCError{status: 5, message: message}} =
             Stub.publish_lifecycle_event(
               channel,
               %V1.PublishLifecycleEventRequest{
                 build_event: Replay.ordered_event(stream_id, 1, attempt)
               },
               metadata: %{"x-api-key" => intruder}
             )

    refute message =~ "default"
    GRPC.Stub.disconnect(channel)
    assert row.() == before
  end

  @tag :capture_log
  test "a failed batch ends the RPC with UNAVAILABLE while the client is still sending",
       %{grpc_port: port, key: key} do
    import Ecto.Query

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}", adapter: GRPC.Client.Adapters.Mint)
    id = Replay.uuid()
    stream_id = %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}
    [e1, e2 | _] = Conveyor.Bep.Fixture.read!(fixture("analysis_failure"))
    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => key})
    request = &%V1.PublishBuildToolEventStreamRequest{ordered_build_event: &1}

    GRPC.Stub.send_request(stream, request.(Replay.ordered_event(stream_id, 1, e1)))
    {:ok, replies} = GRPC.Stub.recv(stream, timeout: 5_000)
    # The acknowledgement echoes the stream id.
    assert [{:ok, %{sequence_number: 1, stream_id: ^stream_id}}] = Enum.take(replies, 1)

    # Another node moved the row: the next batch is fenced. The client neither sends more
    # nor closes its side; the server must end the call on its own.
    Repo.update_all(from(i in Conveyor.Invocations.Invocation, where: i.id == ^id),
      set: [last_event_seq: 99]
    )

    GRPC.Stub.send_request(stream, request.(Replay.ordered_event(stream_id, 2, e2)))

    assert [{:error, %GRPC.RPCError{status: 14, message: "event not persisted" <> _}}] =
             Enum.take(replies, 1)

    GRPC.Stub.disconnect(channel)
  end
end
