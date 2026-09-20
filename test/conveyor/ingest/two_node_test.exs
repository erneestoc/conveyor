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
end
