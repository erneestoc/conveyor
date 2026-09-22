defmodule Conveyor.Ingest.TwoNodeTest do
  @moduledoc """
  Two ingest instances against one database, the way two Conveyor nodes behind a balancer
  see a build whose stream Bazel retried elsewhere: node A's worker is still alive when
  node B resumes the stream. B commits; A's next commit is fenced by the CAS on
  `last_event_seq` and its stream fails; B finishes and the persistence oracle passes.
  """
  use Conveyor.IngestCase, async: false

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Conveyor.Ingest.Verify
  alias Google.Devtools.Build.V1, as: V1

  @moduletag :capture_log

  defp stream_id(id), do: %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}

  defp push(ctx, id, events, range) do
    for seq <- range do
      assert :ok =
               Ingest.push_sync(
                 ctx,
                 Replay.ordered_event(stream_id(id), seq, Enum.at(events, seq - 1))
               )
    end
  end

  defp await_exit(registry, id) do
    case Registry.lookup(registry, id) do
      [] ->
        :ok

      [{pid, _}] ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        :ok
    end
  end

  test "a build resumed on node B fences node A's live worker; B completes", %{ctx: ctx_a} do
    start_supervised!(
      {Ingest.Supervisor,
       name: Conveyor.Ingest.SupervisorB,
       registry: Conveyor.Ingest.RegistryB,
       worker_supervisor: Conveyor.Ingest.WorkerSupervisorB}
    )

    ctx_b = %{
      ctx_a
      | registry: Conveyor.Ingest.RegistryB,
        worker_supervisor: Conveyor.Ingest.WorkerSupervisorB
    }

    id = Replay.uuid()
    events = Fixture.read!(fixture("clean_build_and_test"))
    n = length(events)

    # Node A takes the first part of the stream and stays alive (idle, not finished).
    push(ctx_a, id, events, 1..5)
    assert [{pid_a, _}] = Registry.lookup(Conveyor.Ingest.Registry, id)
    assert reload(id).last_event_seq == 5

    # Bazel retries on node B, which resumes from the database's last committed seq.
    push(ctx_b, id, events, 6..n)
    assert [{pid_b, _}] = Registry.lookup(Conveyor.Ingest.RegistryB, id)
    assert pid_b != pid_a and Process.alive?(pid_a)
    assert reload(id).last_event_seq == n

    # A late event on node A: its commit expects last_event_seq == 5, the row says n;
    # the fence reports the seq it expected the row to be at.
    assert {:error, {:fenced, 5}} =
             Ingest.push_sync(ctx_a, Replay.ordered_event(stream_id(id), 6, Enum.at(events, 5)))

    assert :ok = await_exit(Conveyor.Ingest.Registry, id)
    refute Process.alive?(pid_a)
    assert reload(id).last_event_seq == n

    # B finishes the stream; everything A wrote plus everything B wrote is contiguous.
    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    assert :ok = Ingest.push_sync(ctx_b, Replay.ordered_event(stream_id(id), n + 1, marker))
    assert :ok = await_exit(Conveyor.Ingest.RegistryB, id)
    assert %{status: "succeeded", stream_finished: true} = reload(id)
    assert :ok = Verify.check(id, n)

    # Duplicates after the fact are acknowledged without a second write (dedup on B too).
    assert :ok =
             Ingest.push_sync(ctx_b, Replay.ordered_event(stream_id(id), 3, Enum.at(events, 2)))

    assert :ok = await_exit(Conveyor.Ingest.RegistryB, id)
    assert :ok = Verify.check(id, n)
  end

  test "lifecycle notifications on another node touch the row and never start a worker",
       %{ctx: ctx_a} do
    start_supervised!(
      {Ingest.Supervisor,
       name: Conveyor.Ingest.SupervisorB,
       registry: Conveyor.Ingest.RegistryB,
       worker_supervisor: Conveyor.Ingest.WorkerSupervisorB}
    )

    ctx_b = %{
      ctx_a
      | registry: Conveyor.Ingest.RegistryB,
        worker_supervisor: Conveyor.Ingest.WorkerSupervisorB
    }

    id = Replay.uuid()
    events = Fixture.read!(fixture("clean_build_and_test"))
    n = length(events)
    push(ctx_a, id, events, 1..5)

    # Bazel's lifecycle connection lands on node B: the row is touched, no worker starts
    # there (a stray worker would only fence A's commits; the trial left builds
    # `in_progress` that way).
    started =
      {:invocation_attempt_started, %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}

    assert :ok = Ingest.lifecycle(ctx_b, Replay.ordered_event(stream_id(id), 1, started))
    assert Registry.lookup(Conveyor.Ingest.RegistryB, id) == []
    assert %{last_event_seq: 5} = reload(id)

    # A build that has not started streaming anywhere is visible at once, without a worker.
    fresh = Replay.uuid()
    assert :ok = Ingest.lifecycle(ctx_b, Replay.ordered_event(stream_id(fresh), 1, started))
    assert Registry.lookup(Conveyor.Ingest.RegistryB, fresh) == []
    assert %{status: "in_progress", last_event_seq: 0} = reload(fresh)

    # The stream stays on A and finishes there.
    push(ctx_a, id, events, 6..n)

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    assert :ok = Ingest.push_sync(ctx_a, Replay.ordered_event(stream_id(id), n + 1, marker))

    # The finish notification reaches B, which has no worker: it is recorded directly.
    finished =
      {:invocation_attempt_finished,
       %V1.BuildEvent.InvocationAttemptFinished{
         invocation_status: %V1.BuildStatus{result: :COMMAND_SUCCEEDED}
       }}

    assert :ok = Ingest.lifecycle(ctx_b, Replay.ordered_event(stream_id(id), 2, finished))
    assert :ok = await_exit(Conveyor.Ingest.Registry, id)
    assert %{status: "succeeded", stream_finished: true, lifecycle_finished: true} = reload(id)
    assert :ok = Verify.check(id, n)
  end

  test "a lifecycle finish handled by a stray worker on another node is recorded, not fenced",
       %{ctx: ctx_a} do
    start_supervised!(
      {Ingest.Supervisor,
       name: Conveyor.Ingest.SupervisorB,
       registry: Conveyor.Ingest.RegistryB,
       worker_supervisor: Conveyor.Ingest.WorkerSupervisorB}
    )

    ctx_b = %{
      ctx_a
      | registry: Conveyor.Ingest.RegistryB,
        worker_supervisor: Conveyor.Ingest.WorkerSupervisorB
    }

    id = Replay.uuid()
    events = Fixture.read!(fixture("clean_build_and_test"))
    n = length(events)
    push(ctx_a, id, events, 1..5)

    # Defence in depth: should a worker exist on B anyway (started explicitly here), the
    # finish it fences must still be accepted, or Bazel aborts the whole upload.
    assert {:ok, pid_b} = Ingest.worker(ctx_b, id, stream_id(id))

    started =
      {:invocation_attempt_started, %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}

    assert :ok = Ingest.lifecycle(ctx_b, Replay.ordered_event(stream_id(id), 1, started))
    push(ctx_a, id, events, 6..n)

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    assert :ok = Ingest.push_sync(ctx_a, Replay.ordered_event(stream_id(id), n + 1, marker))

    finished =
      {:invocation_attempt_finished,
       %V1.BuildEvent.InvocationAttemptFinished{
         invocation_status: %V1.BuildStatus{result: :COMMAND_SUCCEEDED}
       }}

    assert :ok = Ingest.lifecycle(ctx_b, Replay.ordered_event(stream_id(id), 2, finished))
    assert :ok = await_exit(Conveyor.Ingest.Registry, id)
    refute Process.alive?(pid_b)
    assert %{status: "succeeded", stream_finished: true, lifecycle_finished: true} = reload(id)
    assert :ok = Verify.check(id, n)
  end

  test "a retried stream landing on a stray worker resumes from the row", %{ctx: ctx_a} do
    start_supervised!(
      {Ingest.Supervisor,
       name: Conveyor.Ingest.SupervisorB,
       registry: Conveyor.Ingest.RegistryB,
       worker_supervisor: Conveyor.Ingest.WorkerSupervisorB}
    )

    ctx_b = %{
      ctx_a
      | registry: Conveyor.Ingest.RegistryB,
        worker_supervisor: Conveyor.Ingest.WorkerSupervisorB
    }

    id = Replay.uuid()
    events = Fixture.read!(fixture("clean_build_and_test"))
    n = length(events)
    push(ctx_a, id, events, 1..5)

    # A worker on B that loaded at seq 5 (the takeover defence; lifecycle events no longer
    # start one).
    assert {:ok, _pid_b} = Ingest.worker(ctx_b, id, stream_id(id))
    push(ctx_a, id, events, 6..n)

    # Bazel retries the stream after a hiccup and the balancer picks node B, whose worker
    # still expects seq 6: it must catch up from the database, not reject seq n + 1.
    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    assert :ok = Ingest.push_sync(ctx_b, Replay.ordered_event(stream_id(id), n + 1, marker))
    assert :ok = await_exit(Conveyor.Ingest.RegistryB, id)
    assert %{status: "succeeded", stream_finished: true} = reload(id)
    assert :ok = Verify.check(id, n)

    # A real gap is still rejected after the reload.
    other = Replay.uuid()
    push(ctx_a, other, events, 1..3)
    assert {:ok, _} = Ingest.worker(ctx_b, other, stream_id(other))

    assert {:error, :out_of_order} =
             Ingest.push_sync(
               ctx_b,
               Replay.ordered_event(stream_id(other), 9, Enum.at(events, 8))
             )
  end
end
