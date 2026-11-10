defmodule Conveyor.Ingest.TenancyTest do
  @moduledoc """
  An invocation id belongs to the project that created it. A context of another project
  that knows the id is refused at the ingest interface (stream and lifecycle), whether or
  not the build has a live worker, and nothing is written.
  """
  use Conveyor.IngestCase, async: false

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Conveyor.Projects
  alias Google.Devtools.Build.V1, as: V1

  @moduletag :capture_log

  @marker {:component_stream_finished,
           %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}
  @started {:invocation_attempt_started,
            %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}
  @finished {:invocation_attempt_finished, %V1.BuildEvent.InvocationAttemptFinished{}}

  defp stream_id(id), do: %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}

  setup %{ctx: ctx} do
    {:ok, other} = Projects.create_project(%{slug: "intruder", name: "Intruder"})
    events = Fixture.read!(fixture("analysis_failure"))
    id = Replay.uuid()

    for seq <- 1..3 do
      assert :ok =
               Ingest.push_sync(
                 ctx,
                 Replay.ordered_event(stream_id(id), seq, Enum.at(events, seq - 1))
               )
    end

    %{id: id, events: events, intruder: %{ctx | project_id: other.id, project_slug: other.slug}}
  end

  defp refused(ctx, intruder, id, events) do
    before = reload(id)

    # The next sequence of the victim's stream, a resend of a committed one, and the marker.
    for {seq, payload} <- [{4, Enum.at(events, 3)}, {2, Enum.at(events, 1)}, {4, @marker}] do
      assert {:error, :not_found} =
               Ingest.push_sync(intruder, Replay.ordered_event(stream_id(id), seq, payload))
    end

    assert {:error, {4, :not_found}} =
             Ingest.push_all(intruder, [
               Replay.ordered_event(stream_id(id), 4, Enum.at(events, 3)),
               Replay.ordered_event(stream_id(id), 5, @marker)
             ])

    assert {:error, :not_found} =
             Ingest.lifecycle(intruder, Replay.ordered_event(stream_id(id), 1, @started))

    # The finish notification of an id the caller cannot see is a no-op, exactly as for an
    # id that does not exist: it must not reveal the build, and must not finish it.
    assert :ok = Ingest.lifecycle(intruder, Replay.ordered_event(stream_id(id), 2, @finished))

    now = reload(id)
    assert now.project_id == ctx.project_id
    assert now.last_event_seq == 3 and not now.stream_finished and not now.lifecycle_finished
    assert now.updated_at == before.updated_at
    assert Ingest.Worker.whereis(intruder.project_id, id) == nil
  end

  test "another project's context cannot append to or finish a live build", %{
    ctx: ctx,
    intruder: intruder,
    id: id,
    events: events
  } do
    assert is_pid(Ingest.Worker.whereis(ctx.project_id, id))
    refused(ctx, intruder, id, events)

    # The owner's stream is not disturbed by the attempts.
    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 4, Enum.at(events, 3)))
    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 5, @marker))
    assert :ok = Ingest.lifecycle(ctx, Replay.ordered_event(stream_id(id), 2, @finished))
    assert :ok = await_worker_exit(id)
    assert %{stream_finished: true, lifecycle_finished: true, last_event_seq: 5} = reload(id)
  end

  test "nor to a build whose worker is gone", %{
    ctx: ctx,
    intruder: intruder,
    id: id,
    events: events
  } do
    pid = Ingest.Worker.whereis(ctx.project_id, id)
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refused(ctx, intruder, id, events)
  end
end
