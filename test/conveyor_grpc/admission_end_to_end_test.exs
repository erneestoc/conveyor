defmodule Conveyor.Grpc.AdmissionEndToEndTest do
  # Admission through the real gRPC server: the pressure is injected at the sampler, so
  # nothing here loads the database.
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.{Admission, Ingest, Limits, Projects}
  alias Conveyor.Admission.Sampler
  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Invocations.Invocation
  alias Google.Devtools.Build.V1, as: V1
  alias Google.Devtools.Build.V1.PublishBuildEvent.Stub

  @unavailable 14
  @resource_exhausted 8

  setup %{project: project} do
    Limits.reset()

    on_exit(fn ->
      Admission.resume()
      Sampler.inject([])
    end)

    {:ok, key, plaintext} = Projects.create_api_key(project, %{name: "admission"})
    {:ok, key: key, api_key: plaintext, events: Fixture.read!(fixture("analysis_failure"))}
  end

  defp open_stream(port, key) do
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)
    stream = Stub.publish_build_tool_event_stream(channel, metadata: %{"x-api-key" => key})
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    stream
  end

  defp stream_id(id), do: %V1.StreamId{build_id: id, invocation_id: id, component: :TOOL}

  defp send_event(stream, id, seq, event, opts \\ []) do
    GRPC.Stub.send_request(
      stream,
      %V1.PublishBuildToolEventStreamRequest{
        ordered_build_event: Replay.ordered_event(stream_id(id), seq, event)
      },
      opts
    )
  end

  # The next answer of the stream: an acknowledged sequence number or the RPC's error.
  defp answer(stream) do
    case GRPC.Stub.recv(stream) do
      {:ok, replies} ->
        case Enum.at(replies, 0) do
          {:ok, %{sequence_number: seq}} -> {:ack, seq}
          {:error, error} -> error
        end

      {:error, error} ->
        error
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "a key at its stream limit is refused until a stream ends", %{
    project: project,
    grpc_port: port,
    events: events
  } do
    {:ok, key, plaintext} =
      Projects.create_api_key(project, %{name: "one", limits: %{"max_streams" => 1}})

    s1 = open_stream(port, plaintext)
    send_event(s1, Replay.uuid(), 1, hd(events))
    assert {:ack, 1} = answer(s1)
    assert Limits.streams(key.id) == 1

    s2 = open_stream(port, plaintext)
    send_event(s2, Replay.uuid(), 1, hd(events), end_stream: true)
    assert %GRPC.RPCError{status: @resource_exhausted, message: "too many" <> _} = answer(s2)

    GRPC.Stub.cancel(s1)
    wait_until(fn -> Limits.streams(key.id) == 0 end)

    assert {:ok, %{sent: sent, acks: acks, invocation_id: id}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    assert length(acks) == sent
    :ok = await_worker_exit(id)
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

    assert {:ok, %{sent: sent, acks: acks, invocation_id: id}} = result
    assert length(acks) == sent
    :ok = await_worker_exit(id)
    # ~98 events at 20/s after the first 20 free tokens: several seconds.
    assert elapsed_us >= 2_000_000
  end

  test "a draining node refuses new streams but still answers lifecycle events", %{
    grpc_port: port,
    api_key: plaintext
  } do
    assert Admission.drain(0) == :ok

    # The server answers UNAVAILABLE; depending on timing the client sees that status or
    # the sender's closed stream first.
    assert {:error, reason} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    assert match?(%GRPC.RPCError{status: @unavailable}, reason) or
             match?({:stream_closed, _}, reason)

    Admission.resume()

    assert {:ok, %{invocation_id: id}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    :ok = await_worker_exit(id)
  end

  test "a shedding node refuses a new build and leaves no row; a build in progress goes on", %{
    grpc_port: port,
    api_key: plaintext,
    events: events,
    key: key,
    project: project
  } do
    ctx = %Ingest.Context{project_id: project.id, project_slug: project.slug, api_key_id: key.id}

    # A build in progress on this node: two events committed.
    old = Replay.uuid()
    s1 = open_stream(port, plaintext)
    send_event(s1, old, 1, Enum.at(events, 0))
    assert {:ack, 1} = answer(s1)

    Sampler.inject(signals: %{oldest_ms: 10_000})
    assert %{state: :shedding} = Admission.state()

    # Its open stream is not touched.
    send_event(s1, old, 2, Enum.at(events, 1))
    wait_until(fn -> Repo.get!(Invocation, old).last_event_seq == 2 end)

    # A new build: refused at its first event, by status, with nothing written.
    new = Replay.uuid()
    s2 = open_stream(port, plaintext)
    send_event(s2, new, 1, hd(events), end_stream: true)

    assert %GRPC.RPCError{status: @unavailable, message: "this node is overloaded" <> _} =
             answer(s2)

    assert Repo.get(Invocation, new) == nil
    assert worker_pid(new) == nil

    # Refused at the lifecycle notification that announces it, too: no row.
    started =
      Replay.ordered_event(
        stream_id(new),
        1,
        {:invocation_attempt_started, %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}
      )

    assert {:error, {:refused, :overloaded}} = Ingest.lifecycle(ctx, started)
    assert Repo.get(Invocation, new) == nil

    assert {:error, {:lifecycle, %GRPC.RPCError{status: @unavailable}}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    # The build in progress reconnects (a resend from its last acknowledgement): taken.
    GRPC.Stub.cancel(s1)
    s3 = open_stream(port, plaintext)
    send_event(s3, old, 3, Enum.at(events, 2))
    assert {:ack, 3} = answer(s3)

    # So is one that comes from another node (no session here, a sequence past the first).
    elsewhere = Replay.uuid()
    {:ok, _} = Ingest.Worker.load_or_create(ctx, elsewhere, stream_id(elsewhere))
    import Ecto.Query, only: [from: 2]
    Repo.update_all(from(i in Invocation, where: i.id == ^elsewhere), set: [last_event_seq: 2])
    s4 = open_stream(port, plaintext)
    send_event(s4, elsewhere, 3, Enum.at(events, 2))
    assert {:ack, 3} = answer(s4)

    # And one whose notification was admitted before the node began to shed: its row
    # exists, its stream starts at the first event.
    announced = Replay.uuid()
    {:ok, _} = Ingest.Worker.load_or_create(ctx, announced, stream_id(announced))
    s5 = open_stream(port, plaintext)
    send_event(s5, announced, 1, Enum.at(events, 0))
    assert {:ack, 1} = answer(s5)
    refute Ingest.announced?(ctx, nil)
    refute Ingest.announced?(ctx, stream_id("not-a-uuid"))

    # Pressure gone: new builds again.
    Sampler.inject([])

    assert {:ok, %{invocation_id: id}} =
             Replay.run(fixture("analysis_failure"), port: port, api_key: plaintext)

    :ok = await_worker_exit(id)
  end

  test "at the deadline an open stream's next event is refused: never acknowledged, resent later",
       %{grpc_port: port, api_key: plaintext, events: events} do
    id = Replay.uuid()
    s1 = open_stream(port, plaintext)
    send_event(s1, id, 1, Enum.at(events, 0))
    assert {:ack, 1} = answer(s1)

    # Batches are about to expire: every stream's events are refused.
    Sampler.inject(signals: %{oldest_ms: 21_000})
    assert %{state: :critical, events_refused_pct: 100} = Admission.state()

    send_event(s1, id, 2, Enum.at(events, 1))

    assert %GRPC.RPCError{status: @unavailable, message: "this node is overloaded" <> _} =
             answer(s1)

    # The refused event was not handed to the session: the row holds what was acknowledged.
    assert Repo.get!(Invocation, id).last_event_seq == 1

    # A reconnect is refused too, at its first event: the build stays shed.
    s2 = open_stream(port, plaintext)
    send_event(s2, id, 2, Enum.at(events, 1), end_stream: true)
    assert %GRPC.RPCError{status: @unavailable} = answer(s2)

    # The client retries after the pressure is gone and resumes from its last ack.
    Sampler.inject([])

    assert {:ok, %{acks: acks}} =
             Replay.run(events, port: port, api_key: plaintext, invocation_id: id)

    assert List.last(acks) == length(events) + 1
    :ok = await_worker_exit(id)
    assert :ok = Ingest.Verify.check(id, length(events))
  end

  test "a client that retries like Bazel gets its retries back after progress", %{
    grpc_port: port,
    api_key: plaintext,
    events: events
  } do
    # The node turns critical after the first and after the fourth acknowledgement, and
    # recovers at each reconnect: two failed attempts with progress in between. One retry
    # is enough when the budget is counted anew after progress, and is not otherwise.
    acks = :counters.new(1, [])
    test = self()

    :telemetry.attach_many(
      "bazel-retry",
      [[:conveyor, :ingest, :ack], [:conveyor, :loadgen, :reconnect]],
      fn
        [_, :ingest, :ack], _, _, _ ->
          :counters.add(acks, 1, 1)
          if :counters.get(acks, 1) in [1, 4], do: Sampler.inject(signals: %{oldest_ms: 21_000})

        [_, :loadgen, :reconnect], %{attempt: attempt}, _, _ ->
          send(test, {:reconnect, attempt})
          Sampler.inject([])
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("bazel-retry") end)

    opts = [port: port, api_key: plaintext, delay_ms: 40, lifecycle: false]

    assert {:ok, %{attempts: 3, acks: acked, invocation_id: id}} =
             Replay.run(events, opts ++ [retries: 1, retry_delay_ms: 5])

    assert Enum.uniq(acked) == Enum.to_list(1..(length(events) + 1))
    assert_received {:reconnect, 1}
    assert_received {:reconnect, 2}
    :ok = await_worker_exit(id)

    # The default policy counts every reconnect: the same two failures need two retries.
    :counters.put(acks, 1, 0)

    assert {:error, %GRPC.RPCError{status: @unavailable}} =
             Replay.run(events, opts ++ [retries: 1])
  end

  test "refusals are answers, not faults: they are not logged as handler errors" do
    alias Conveyor.Grpc.Endpoint
    report = fn reason -> GRPC.Server.Adapters.ReportException.new([req: :ok], reason) end

    refute Endpoint.log_exception?(report.(Admission.grpc_error(:overloaded)))
    refute Endpoint.log_exception?(report.(Admission.grpc_error(:key_streams)))

    assert Endpoint.log_exception?(
             report.(GRPC.RPCError.exception(status: :internal, message: "x"))
           )

    assert Endpoint.log_exception?(report.(%RuntimeError{message: "boom"}))
    assert Endpoint.server_opts(1)[:exception_log_filter] == {Endpoint, :log_exception?}
  end

  test "push_all (the HTTP upload, the seed) passes the same doors", %{
    ctx: ctx,
    events: events
  } do
    id = Replay.uuid()

    stream = fn from ->
      for {e, seq} <- Enum.with_index(events, 1),
          seq >= from,
          do: Replay.ordered_event(stream_id(id), seq, e)
    end

    Sampler.inject(signals: %{oldest_ms: 10_000})
    assert {:error, {1, {:refused, :overloaded}}} = Ingest.push_all(ctx, stream.(1))
    assert Repo.get(Invocation, id) == nil
    assert Admission.streams() == 0

    Sampler.inject(signals: %{oldest_ms: 16_000})
    assert {:error, {1, {:refused, :overloaded}}} = Ingest.push_all(ctx, stream.(1))
    assert Admission.streams() == 0

    Sampler.inject([])
    assert :ok = Ingest.push_all(ctx, Enum.take(stream.(1), 2))
    # A resumed stream under shedding: taken.
    Sampler.inject(signals: %{oldest_ms: 10_000})
    assert :ok = Ingest.push_all(ctx, stream.(3))
    assert Repo.get!(Invocation, id).last_event_seq == length(events)

    Admission.drain(0)
    assert {:error, {0, {:refused, :draining}}} = Ingest.push_all(ctx, stream.(1))
  end
end
