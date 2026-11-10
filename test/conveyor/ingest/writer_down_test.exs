defmodule Conveyor.Ingest.WriterDownTest do
  @moduledoc """
  The delivery contract between a worker and its writer shard: every submitted batch gets
  one outcome, and a writer that goes away with batches in hand is such an outcome. The
  worker fails the stream instead of waiting for a message that will never come; the
  client's resend then goes through the row.
  """
  use Conveyor.IngestCase, async: false

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Conveyor.Ingest.{Verify, WriterPool}
  alias Google.Devtools.Build.V1, as: V1

  @moduletag :capture_log

  @marker {:component_stream_finished,
           %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

  defp stream_id(id), do: %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}

  test "a writer killed with batches in flight fails the stream; the resend completes the build",
       %{ctx: ctx} do
    id = Replay.uuid()
    events = Fixture.read!(fixture("analysis_failure"))
    n = length(events)
    obe = fn seq -> Replay.ordered_event(stream_id(id), seq, Enum.at(events, seq - 1)) end

    assert :ok = Ingest.push_sync(ctx, obe.(1))
    worker = worker_pid(id)
    worker_ref = Process.monitor(worker)

    # The writer holds the batch (it is suspended, so the cast sits in its mailbox) when it
    # dies; the marker makes the worker flush at once, and its ack is the one a gRPC
    # handler would be waiting on for ever.
    writer = Conveyor.Ingest.Writer.whereis(WriterPool.for_invocation(id))
    :ok = :sys.suspend(writer)
    for seq <- 2..n, do: assert(:ok = Ingest.push(ctx, obe.(seq), self()))
    assert :ok = Ingest.push(ctx, Replay.ordered_event(stream_id(id), n + 1, @marker), self())
    Process.exit(writer, :kill)

    for seq <- 2..(n + 1), do: assert_receive({:ack_failed, ^seq, :writer_down}, 2_000)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000
    assert reload(id).last_event_seq == 1

    # Bazel resends from its last acknowledgement: a new worker starts from the row, the
    # restarted writer commits.
    for seq <- 1..n, do: assert(:ok = Ingest.push(ctx, obe.(seq), self()))
    assert :ok = Ingest.push(ctx, Replay.ordered_event(stream_id(id), n + 1, @marker), self())
    for seq <- 1..(n + 1), do: assert_receive({:ack, ^seq}, 5_000)
    assert :ok = await_worker_exit(id)
    assert :ok = Verify.check(id, n)
  end

  test "a batch submitted while no writer is registered fails at once", %{ctx: ctx} do
    assert {:error, :writer_down} =
             Ingest.Writer.submit(
               :no_such_shard,
               Ingest.Batch.new(Replay.uuid(), ctx.project_id, Date.utc_today(), 1, 0, 0)
             )
  end

  test "a writer that restarts while the worker has nothing in flight is picked up again", %{
    ctx: ctx
  } do
    id = Replay.uuid()
    events = Fixture.read!(fixture("analysis_failure"))
    obe = fn seq -> Replay.ordered_event(stream_id(id), seq, Enum.at(events, seq - 1)) end
    assert :ok = Ingest.push_sync(ctx, obe.(1))
    worker = worker_pid(id)

    writer = Conveyor.Ingest.Writer.whereis(WriterPool.for_invocation(id))
    ref = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^writer, :killed}
    # Both have handled the exit: the pool restarted the shard, the worker dropped its watch.
    _ = Supervisor.which_children(WriterPool)
    _ = :sys.get_state(worker)

    assert :ok = Ingest.push_sync(ctx, obe.(2))
    assert worker_pid(id) == worker
    assert reload(id).last_event_seq == 2
  end
end
