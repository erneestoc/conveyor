defmodule Conveyor.Ingest.WorkerTest do
  @moduledoc """
  The worker end to end: recorded builds through the real session, writer and database.
  The protocol's rules (dedup, gaps, takeover, back-pressure, idle, linger, finalize) are
  tested on `Conveyor.Ingest.Session` in `session_test.exs`; what is left here is what only
  the process can show: the row, the writer, timers that really fire, hibernation.
  """
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

  defp session(overrides), do: struct(Ingest.session_config(), overrides)

  # Waits (without sleeping the test) until the worker has gone into hibernation.
  defp hibernated?(pid, tries \\ 100) do
    case Process.info(pid, :current_function) do
      {:current_function, {mod, fun, _}}
      when {mod, fun} in [{:erlang, :hibernate}, {:gen_server, :loop_hibernate}] ->
        true

      _ when tries > 0 ->
        receive do
        after
          20 -> hibernated?(pid, tries - 1)
        end

      _ ->
        false
    end
  end

  @tag :capture_log
  test "persists a full build, finalizes and exits after lingering", %{ctx: ctx} do
    ctx = %{ctx | session: session(linger_ms: 2_000)}
    id = Replay.uuid()
    events = events("clean_build_and_test")
    Conveyor.Watch.subscribe(Ingest.project_topic(ctx.project_id))
    Conveyor.Watch.subscribe(Ingest.invocation_topic(id))
    Conveyor.Watch.subscribe(Ingest.log_topic(id))

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

    # The notification creates the row (the build is visible at once) but starts no worker.
    assert %{status: "in_progress", last_event_seq: 0} = reload(id)
    assert worker_pid(id) == nil
    push_all(ctx, id, Enum.take(events, 3))
    assert %{status: "in_progress", finalized: false} = Worker.summary(ctx.project_id, id)
    push_all(ctx, id, events, 4)
    finish(ctx, id, length(events) + 1)

    # A finished worker hibernates at once, and on its next quiet tick (the one that
    # publishes the final digest) drops the wide columns it will never read again
    # (PLAN §24 item 5); it still answers.
    pid = worker_pid(id)
    assert hibernated?(pid)
    assert_receive {:invocation_detail, %{invocation: %{finalized: true}}}, 2_000
    summary = Worker.summary(ctx.project_id, id)
    assert summary.finalized and not Map.has_key?(summary, :options)

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
    # The fixture's profile is a local file: settled in the final batch, no fetch job.
    assert inv.profile_status == "unavailable" and inv.profile_uri =~ "file://"
    assert :ok = Ingest.Verify.check(id, length(events))
    assert length(Invocations.events(inv)) == length(events)
    assert Invocations.log(inv) =~ "Build completed successfully"
    assert length(Invocations.targets(inv)) == 5
    assert length(Invocations.test_results(inv)) == 5
    assert Invocations.actions(inv) != [] and Invocations.metrics(inv).build_metrics != %{}
    # The file-set graph stays in the raw events only (PLAN §26.1): no derived rows.
    assert Enum.any?(events, &match?(%{payload: {:named_set_of_files, _}}, &1))

    assert %{rows: [[0, 0]]} =
             Conveyor.Repo.query!(
               """
               SELECT (SELECT count(*) FROM named_sets WHERE invocation_id = $1),
                      (SELECT count(*) FROM targets
                       WHERE invocation_id = $1 AND output_groups <> '{}')
               """,
               [Ecto.UUID.dump!(id)]
             )

    assert [%{byte_offset: 0, line_offset: 0} | _] = Invocations.log_segments(inv)
    Conveyor.Ingest.TagCounter.flush()
    assert Enum.any?(Invocations.tag_keys(ctx.project_id, limit: 50), &(&1.key == "scenario"))

    assert_received {:invocation_updated, %{id: ^id}}
    assert_received {:invocation_detail, %{invocation: %{id: ^id}}}
    assert_received {:log_chunks, [_ | _], 0}
  end

  @tag :capture_log
  test "a worker that restarts resumes from the row; resends and gaps are judged against it",
       %{ctx: ctx} do
    id = Replay.uuid()
    events = events("test_failure")
    push_all(ctx, id, Enum.take(events, 10))

    # Duplicates (a retry) are acked without being stored again; a gap is refused.
    assert :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 3, Enum.at(events, 2)))

    assert {:error, :out_of_order} =
             Ingest.push_sync(ctx, Replay.ordered_event(stream_id(id), 12, Enum.at(events, 11)))

    assert %{last_event_seq: 10} = Worker.summary(ctx.project_id, id)

    # Simulate a node restart: stop the worker, then continue from where the DB says.
    pid = worker_pid(id)
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

    push_all(%{ctx | session: session(idle_timeout_ms: 50)}, id, Enum.take(events, 5))
    assert :ok = await_worker_exit(id, 3_000)
    assert %{status: "disconnected", finished_at: %DateTime{}} = reload(id)

    push_all(ctx, id, events, 6)
    finish(ctx, id, length(events) + 1)
    assert :ok = await_worker_exit(id)
    assert reload(id).status == "failed"
  end

  @tag :capture_log
  test "a client back within the linger after an idle disconnect continues on the same worker",
       %{ctx: ctx} do
    id = Replay.uuid()
    events = events("build_failure")
    n = length(events)
    ctx = %{ctx | session: session(idle_timeout_ms: 100, linger_ms: 2_000)}
    Conveyor.Watch.subscribe(Ingest.invocation_topic(id))

    push_all(ctx, id, Enum.take(events, 5))
    worker = worker_pid(id)
    ref = Process.monitor(worker)
    assert_receive {:invocation_detail, %{invocation: %{status: "disconnected"}}}, 2_000

    # The whole rest of the stream, at once: no further idle window, and the worker (which
    # reloads the row and drops the linger) is the one that finalizes the build.
    rest =
      events
      |> Enum.with_index(1)
      |> Enum.drop(5)
      |> Enum.map(fn {event, seq} -> Replay.ordered_event(stream_id(id), seq, event) end)

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    assert :ok =
             Ingest.push_all(ctx, rest ++ [Replay.ordered_event(stream_id(id), n + 1, marker)])

    assert worker_pid(id) == worker
    assert %{status: "failed", stream_finished: true, last_event_seq: last} = reload(id)
    assert last == n + 1
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert :ok = Ingest.Verify.check(id, n)
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

    assert %Ingest.Session.Config{linger_ms: 0, max_unacked_events: 2_000} =
             Ingest.session_config()

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

    assert :ok = Ingest.push_all(ctx, [])

    assert {:error, {4, {:fenced, 3}}} =
             Ingest.push_all(ctx, [Replay.ordered_event(stream_id(id), 4, Enum.at(events, 3))])

    assert :ok = await_worker_exit(id)
  end

  @tag :capture_log
  test "a database error while recording a finish notification is reported as unavailable", %{
    ctx: ctx
  } do
    id = Replay.uuid()
    push_all(ctx, id, Enum.take(events("analysis_failure"), 2))
    worker = worker_pid(id)
    ref = Process.monitor(worker)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}

    finished =
      Replay.ordered_event(
        stream_id(id),
        2,
        {:invocation_attempt_finished, %V1.BuildEvent.InvocationAttemptFinished{}}
      )

    # The statement fails in the database (rolled back with the sandbox transaction).
    Repo.query!("ALTER TABLE invocations RENAME COLUMN lifecycle_finished TO renamed")
    assert {:error, {:unavailable, %Postgrex.Error{}}} = Ingest.lifecycle(ctx, finished)
    Repo.query!("ALTER TABLE invocations RENAME COLUMN renamed TO lifecycle_finished")
    assert :ok = Ingest.lifecycle(ctx, finished)
    assert reload(id).lifecycle_finished
  end
end
