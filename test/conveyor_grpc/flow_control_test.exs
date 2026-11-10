defmodule Conveyor.Grpc.FlowControlTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Bep.Replay
  alias Conveyor.Grpc.FlowControl
  alias Conveyor.Projects
  alias Google.Devtools.Build.V1, as: V1
  alias Google.Devtools.Build.V1.PublishBuildEvent.Stub

  @chunk 64 * 1024
  @chunks 128

  defp progress(seq, bytes) do
    %BuildEventStream.BuildEvent{
      id: %BuildEventStream.BuildEventId{
        id: {:progress, %BuildEventStream.BuildEventId.ProgressId{opaque_count: seq}}
      },
      payload: {:progress, %BuildEventStream.Progress{stdout: String.duplicate("x", bytes)}}
    }
  end

  defp request(stream_id, seq, bytes) do
    %V1.PublishBuildToolEventStreamRequest{
      ordered_build_event: Replay.ordered_event(stream_id, seq, progress(seq, bytes))
    }
  end

  # Request bytes the server's connection processes hold: the stream handler's buffer and
  # frames not yet parsed are binaries referenced from those processes.
  defp held_bytes(connections) do
    connections
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, :binary) do
        {:binary, binaries} -> binaries
        nil -> []
      end
    end)
    |> Enum.uniq_by(fn {id, _size, _refs} -> id end)
    |> Enum.reduce(0, fn {_id, size, _refs}, sum -> sum + size end)
  end

  defp connections, do: :ranch.procs(inspect(Conveyor.Grpc.Endpoint), :connections)

  test "a reader that stops reading closes the client's window", %{
    project: project,
    grpc_port: port
  } do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "flow"})
    before = connections()

    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)
    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => plaintext})
    id = Replay.uuid()
    stream_id = %V1.StreamId{build_id: id, invocation_id: id, component: :TOOL}

    GRPC.Stub.send_request(stream, request(stream_id, 1, 10))
    assert {:ok, replies} = GRPC.Stub.recv(stream)
    assert {:ok, %{sequence_number: 1}} = Enum.at(replies, 0)
    [connection] = connections() -- before

    # The session stops answering: the handler blocks in its push and reads no further.
    worker = worker_pid(id)
    :ok = :sys.suspend(worker)

    # 8 MB of events. The client blocks in its send once the window is closed (which is
    # the back-pressure Bazel feels), so the sends run beside the test.
    sender =
      Task.async(fn ->
        for seq <- 2..(@chunks + 1),
            do: GRPC.Stub.send_request(stream, request(stream_id, seq, @chunk))
      end)

    # Let the server take what it will: the held bytes stop growing.
    held =
      Enum.reduce_while(1..100, 0, fn _, last ->
        Process.sleep(50)
        now = held_bytes([connection])
        if now == last and now > 0, do: {:halt, now}, else: {:cont, now}
      end)

    # One window (65,535 bytes), one frame and cowboy's margin; it was all 8 MB.
    assert held < 1024 * 1024,
           "the connection holds #{held} bytes of a stalled stream: flow control is not applied"

    # Reading again opens the window: every event arrives and is acknowledged.
    :ok = :sys.resume(worker)
    Task.await(sender, 30_000)

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    GRPC.Stub.send_request(
      stream,
      %V1.PublishBuildToolEventStreamRequest{
        ordered_build_event: Replay.ordered_event(stream_id, @chunks + 2, marker)
      },
      end_stream: true
    )

    wait_until(fn ->
      Repo.get!(Conveyor.Invocations.Invocation, id).last_event_seq == @chunks + 2
    end)

    GRPC.Stub.disconnect(channel)
    :ok = await_worker_exit(id)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end

  test "the server is started with the handler in front of the library's" do
    assert FlowControl.adapter_opts()[:stream_handlers] == [FlowControl, :grpc_stream_h]

    assert %{stream_handlers: [FlowControl, :grpc_stream_h]} =
             :ranch.get_protocol_options(inspect(Conveyor.Grpc.Endpoint))
  end

  describe "the handler, command by command" do
    defmodule Inner do
      @moduledoc false
      # Stands for grpc_stream_h: grants on every frame, and on a read that finds a buffer.
      def init(_id, _req, _opts), do: {[], 0}

      def data(_id, _fin, data, buffered),
        do: {[{:flow, byte_size(data)}, :other], buffered + byte_size(data)}

      def info(_id, {:read_body, _, _, _, _}, 0), do: {[], 0}
      def info(_id, {:read_body, _, _, _, _}, buffered), do: {[{:flow, buffered}], 0}
      def info(_id, _info, buffered), do: {[:passed], buffered}
      def terminate(_id, _reason, _state), do: :ok
      def early_error(_id, _reason, _req, resp, _opts), do: resp
    end

    test "data nobody waits for is not granted until it is read" do
      read = {:read_body, self(), make_ref(), 8_000_000, 15_000}
      {[], s} = FlowControl.init(1, %{}, %{stream_handlers: [Inner]})

      # Arrives before any read: buffered, no window.
      {[:other], s} = FlowControl.data(1, :nofin, "12345", s)
      {[:other], s} = FlowControl.data(1, :nofin, "678", s)
      # The read takes the buffer and grants its size.
      {[{:flow, 8}], s} = FlowControl.info(1, read, s)
      # Still not waiting: the next frame is buffered again.
      {[:other], s} = FlowControl.data(1, :nofin, "ab", s)
      {[{:flow, 2}], s} = FlowControl.info(1, read, s)
      # A read that finds nothing waits; the frame that answers it is granted at once.
      {[], s} = FlowControl.info(1, read, s)
      {[{:flow, 3}, :other], s} = FlowControl.data(1, :nofin, "xyz", s)
      # Other messages pass and change nothing.
      {[:passed], s} = FlowControl.info(1, :anything, s)
      {[:other], s} = FlowControl.data(1, :fin, "z", s)
      assert :ok = FlowControl.terminate(1, :normal, s)
      assert :resp = FlowControl.early_error(1, :reason, %{}, :resp, %{stream_handlers: [Inner]})
    end
  end
end
