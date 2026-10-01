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

  # The worker of a live build is suspended so the server stops acknowledging while the
  # client still has events in flight: a connection that died silently behind a balancer.
  defp suspend_worker_once_live(invocation_id) do
    # Only once a few events were acknowledged, so the resume has somewhere to start from.
    handler = "replay-test-acks-#{invocation_id}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:conveyor, :ingest, :ack],
      fn _, _, _, _ -> send(test_pid, :acked) end,
      nil
    )

    for _ <- 1..3, do: assert_receive(:acked, 5_000)
    :telemetry.detach(handler)
    [{worker, _}] = Registry.lookup(Conveyor.Ingest.Registry, invocation_id)
    :ok = :sys.suspend(worker)
    worker
  end

  @tag :capture_log
  test "resumes a build from its last acknowledged event on a fresh connection when acks stop",
       %{grpc_port: port, key: key} do
    id = Replay.uuid()
    test_pid = self()

    # The reconnect lets the server go again, so the resumed stream can complete.
    :telemetry.attach(
      "replay-test-reconnect",
      [:conveyor, :loadgen, :reconnect],
      fn _, m, meta, _ ->
        [{worker, _}] = Registry.lookup(Conveyor.Ingest.Registry, meta.invocation_id)
        :ok = :sys.resume(worker)
        send(test_pid, {:reconnect, m, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("replay-test-reconnect") end)

    task =
      Task.async(fn ->
        Replay.run(fixture("clean_build_and_test"),
          port: port,
          api_key: key,
          invocation_id: id,
          delay_ms: 20,
          ack_timeout_ms: 300,
          retries: 2
        )
      end)

    suspend_worker_once_live(id)

    assert_receive {:reconnect, %{attempt: 1},
                    %{invocation_id: ^id, reason: {:stream_closed, :ack_timeout}, from_seq: from}},
                   5_000

    assert from > 1

    assert {:ok, %{invocation_id: ^id, attempts: 2, acks: acks, sent: sent}} =
             Task.await(task, 30_000)

    assert Enum.sort(Enum.uniq(acks)) == Enum.to_list(1..sent)
    :ok = await_worker_exit(id)
    assert :ok = Conveyor.Ingest.Verify.check(id, sent - 1)
    assert Repo.aggregate(Conveyor.Invocations.Invocation, :count) == 1
  end

  @tag :capture_log
  test "gives the build up when acks stop and no retry is left", %{grpc_port: port, key: key} do
    id = Replay.uuid()

    task =
      Task.async(fn ->
        Replay.run(fixture("clean_build_and_test"),
          port: port,
          api_key: key,
          invocation_id: id,
          delay_ms: 20,
          ack_timeout_ms: 200
        )
      end)

    worker = suspend_worker_once_live(id)
    assert {:error, {:stream_closed, :ack_timeout}} = Task.await(task, 30_000)

    :ok = :sys.resume(worker)
    ref = Process.monitor(worker)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
  end

  test "generates RFC 4122 version 4 uuids" do
    assert Replay.uuid() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert Replay.uuid() != Replay.uuid()
  end
end
