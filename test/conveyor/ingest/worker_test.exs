defmodule Conveyor.Ingest.WorkerTest do
  use Conveyor.IngestCase, async: false

  import Ecto.Query

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Conveyor.Ingest.Worker
  alias Conveyor.Invocations
  alias Google.Devtools.Build.V1, as: V1

  defp stream_id(id), do: %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}
  defp events(name), do: Fixture.read!(fixture(name))

  defp push_all(ctx, id, events, from \\ 1) do
    events
    |> Enum.with_index(1)
    |> Enum.drop(from - 1)
    |> Enum.each(fn {event, seq} ->
      assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), seq, event))
    end)
  end

  defp finish(ctx, id, seq) do
    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), seq, marker))
  end

  @tag :capture_log
  test "persists a full build, finalizes and exits after lingering", %{ctx: ctx} do
    id = Replay.uuid()
    events = events("clean_build_and_test")
    Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.project_topic(ctx.project_id))
    Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.invocation_topic(id))
    Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.log_topic(id))

    assert :ok =
             Ingest.lifecycle(
               ctx,
               Replay.ordered_event(
                 stream_id(id),
                 1,
                 {:invocation_attempt_started,
                  %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}
               )
             )

    assert %{status: "in_progress", finalized: false} = Worker.summary(id)
    push_all(ctx, id, events)
    finish(ctx, id, length(events) + 1)

    assert :ok =
             Ingest.lifecycle(
               ctx,
               Replay.ordered_event(
                 stream_id(id),
                 2,
                 {:invocation_attempt_finished, %V1.BuildEvent.InvocationAttemptFinished{}}
               )
             )

    assert :ok =
             Ingest.lifecycle(
               ctx,
               Replay.ordered_event(
                 %{stream_id(id) | invocation_id: ""},
                 2,
                 {:build_finished, %V1.BuildEvent.BuildFinished{}}
               )
             )

    assert :ok = await_worker_exit(id)

    inv = reload(id)
    assert inv.status == "succeeded" and inv.stream_finished and inv.lifecycle_finished
    assert inv.last_event_seq == length(events) + 1 and inv.event_count == length(events)
    assert :ok = Ingest.Verify.check(id, length(events))
    assert length(Invocations.events(inv)) == length(events)
    assert Invocations.log(inv) =~ "Build completed successfully"
    assert length(Invocations.targets(inv)) == 5
    assert length(Invocations.test_results(inv)) == 5
    assert Invocations.actions(inv) != [] and Invocations.metrics(inv).build_metrics != %{}
    assert map_size(Invocations.named_sets(inv)) > 0
    assert [%{byte_offset: 0, line_offset: 0} | _] = Invocations.log_segments(inv)
    Conveyor.Ingest.TagCounter.flush()
    assert Enum.any?(Invocations.tag_keys(ctx.project_id, limit: 50), &(&1.key == "scenario"))

    assert_received {:invocation_updated, %{id: ^id}}
    assert_received {:invocation_detail, %{invocation: %{id: ^id}}}
    assert_received {:log_chunks, [_ | _], 0}
  end

  @tag :capture_log
  test "deduplicates resent events, rejects gaps, and rehydrates after a restart", %{ctx: ctx} do
    id = Replay.uuid()
    events = events("test_failure")
    push_all(ctx, id, Enum.take(events, 10))

    # Duplicates (a retry) are acked without being stored again; a gap is refused.
    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 3, Enum.at(events, 2)))

    assert {:error, :out_of_order} =
             Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 12, Enum.at(events, 11)))

    assert %{last_event_seq: 10} = Worker.summary(id)

    # Simulate a node restart: stop the worker, then continue from where the DB says.
    [{pid, _}] = Registry.lookup(Conveyor.Ingest.Registry, id)
    GenServer.stop(pid)
    assert reload(id).last_event_seq == 10
    push_all(ctx, id, events, 11)
    finish(ctx, id, length(events) + 1)
    assert :ok = await_worker_exit(id)
    assert :ok = Ingest.Verify.check(id, length(events))
    assert reload(id).status == "failed"
  end

  @tag :capture_log
  test "an idle stream is marked disconnected and a later reconnect can still finish it", %{
    ctx: ctx
  } do
    id = Replay.uuid()
    events = events("build_failure")
    previous = Application.get_env(:conveyor, Ingest)
    Application.put_env(:conveyor, Ingest, Keyword.put(previous, :idle_timeout_ms, 50))
    on_exit(fn -> Application.put_env(:conveyor, Ingest, previous) end)

    push_all(ctx, id, Enum.take(events, 5))
    assert :ok = await_worker_exit(id, 3_000)
    assert %{status: "disconnected", finished_at: %DateTime{}} = reload(id)

    Application.put_env(:conveyor, Ingest, previous)
    push_all(ctx, id, events, 6)
    finish(ctx, id, length(events) + 1)
    assert :ok = await_worker_exit(id)
    assert reload(id).status == "failed"
  end

  @tag :capture_log
  test "backpressure defers the push reply until a commit lands", %{ctx: ctx} do
    id = Replay.uuid()
    events = events("clean_build_and_test")
    previous = Application.get_env(:conveyor, Ingest)

    Application.put_env(
      :conveyor,
      Ingest,
      previous |> Keyword.put(:max_unacked_events, 2) |> Keyword.put(:batch_flush_ms, 30)
    )

    on_exit(fn -> Application.put_env(:conveyor, Ingest, previous) end)

    for {event, seq} <- events |> Enum.take(6) |> Enum.with_index(1) do
      assert :ok = Ingest.push(ctx, Replay.ordered_event(stream_id(id), seq, event), self())
    end

    for seq <- 1..6, do: assert_receive({:ack, ^seq}, 2_000)
  end

  @tag :capture_log
  test "malformed and control events are acked but not stored", %{ctx: ctx} do
    id = Replay.uuid()

    bad =
      {:bazel_event,
       %Google.Protobuf.Any{
         type_url: "type.googleapis.com/build_event_stream.BuildEvent",
         value: <<0xFF, 0xFF>>
       }}

    console =
      {:console_output, %V1.BuildEvent.ConsoleOutput{type: :STDERR, output: {:text_output, "x"}}}

    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 1, bad))
    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 2, console))
    finish(ctx, id, 3)
    assert :ok = await_worker_exit(id)
    inv = reload(id)
    assert inv.status == "unknown" and inv.event_count == 0 and inv.last_event_seq == 3
    assert Invocations.raw_frames(inv) == []
  end

  test "events without an invocation id and unknown lifecycle kinds are handled", %{ctx: ctx} do
    obe =
      Replay.ordered_event(
        %V1.StreamId{invocation_id: ""},
        1,
        {:build_enqueued, %V1.BuildEvent.BuildEnqueued{}}
      )

    assert {:error, :missing_invocation_id} = Ingest.push(ctx, obe, self())
    assert :ok = Ingest.lifecycle(ctx, obe)
    assert Ingest.config(:missing_key, :default) == :default
    assert Ingest.all_topic() == "invocations:all"
  end

  @tag :capture_log
  test "a fenced worker fails its stream", %{ctx: ctx} do
    id = Replay.uuid()
    events = events("analysis_failure")
    push_all(ctx, id, Enum.take(events, 3))
    # Someone else (another node) advanced the row: the next commit must be fenced.
    Repo.update_all(from(i in Invocations.Invocation, where: i.id == ^id),
      set: [last_event_seq: 99]
    )

    assert {:error, {:fenced, 3}} =
             Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 4, Enum.at(events, 3)))

    assert :ok = await_worker_exit(id)
  end
end
