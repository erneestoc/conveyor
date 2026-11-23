defmodule Conveyor.Rbe.StreamIngestTest do
  @moduledoc """
  The per-action records of a recorded build through the real ingest path: one record
  per successful `ActionExecuted`, committed exactly once with the batch that
  acknowledged the event, whatever happens to the stream (PLAN §28).
  """
  use Conveyor.IngestCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  import Ecto.Query

  alias Conveyor.Bep.Replay
  alias Conveyor.Ingest
  alias Conveyor.Rbe.{Stream, StreamActions, StreamChunk}
  alias Conveyor.StreamFixture

  @moduletag :capture_log

  # What the records of a stream must be, computed from its events without the pipeline.
  defp expected(events) do
    build_start =
      Enum.find_value(events, fn
        %{payload: {:started, s}} -> us(s.start_time)
        _ -> nil
      end)

    for {%{id: %{id: {:action_completed, aid}}, payload: {:action, %{success: true} = a}}, seq} <-
          Enum.with_index(events, 1) do
      StreamActions.record(
        aid.label,
        a.type,
        aid.primary_output,
        a.command_line,
        us(a.start_time),
        us(a.end_time),
        build_start,
        seq
      )
    end
  end

  defp us(nil), do: nil
  defp us(t), do: t.seconds * 1_000_000 + div(t.nanos, 1_000)

  defp chunks(id) do
    Repo.all(
      from c in StreamChunk,
        where: c.invocation_id == ^id,
        order_by: c.first_seq,
        select: {c.first_seq, c.n, fragment("octet_length(?)", c.records)}
    )
  end

  defp push(ctx, id, events, range) do
    for seq <- range do
      obe = Replay.ordered_event(StreamFixture.stream_id(id), seq, Enum.at(events, seq - 1))
      assert :ok = Ingest.push_sync(ctx, obe)
    end
  end

  test "recorded builds: one record per successful action, in chunks, and their size", %{
    ctx: ctx
  } do
    IO.puts("")

    for name <- ~w(buildtools_a1 buildtools_a1_warm abseil_a1 bazel_8_4 bazel_7_6) do
      events = StreamFixture.events(name)
      id = StreamFixture.ingest!(ctx, events)
      records = Stream.records(id)
      assert records == expected(events)

      inv = reload(id)
      assert inv.stream_actions == length(records)
      # The end of the build schedules its key merge (once per build).
      assert [_] = all_enqueued(worker: Conveyor.Workers.StreamKeys, args: %{invocation_id: id})
      assert :ok = Ingest.Verify.check(id, length(events))

      chunks = chunks(id)
      assert Enum.sum(Enum.map(chunks, &elem(&1, 1))) == length(records)
      bytes = Enum.sum(Enum.map(chunks, &elem(&1, 2)))
      executed = Enum.count(records, &StreamActions.execution?/1)
      hits = Enum.count(records, &elem(&1, 5))

      IO.puts(
        "stream records #{name}: #{length(records)} actions (#{executed} executed, #{hits} hits) " <>
          "in #{length(chunks)} chunks, #{bytes} B, " <>
          "#{Float.round(bytes / max(length(records), 1), 1)} B per action"
      )

      if name in ~w(buildtools_a1 abseil_a1), do: assert(bytes / length(records) <= 30)
    end
  end

  test "the commit of a build comes from the tags Conveyor keeps; it is optional", %{ctx: ctx} do
    with_commit = StreamFixture.events("bazel_8_6", tags: %{"commit" => "abc123"})
    assert Stream.commit(reload(StreamFixture.ingest!(ctx, with_commit)).tags) == "abc123"
    assert Stream.commit(%{"build_scm_revision" => "def"}) == "def"

    assert Stream.commit(
             reload(StreamFixture.ingest!(ctx, StreamFixture.events("bazel_8_6"))).tags
           ) == nil

    assert Stream.commit(nil) == nil
  end

  test "the version gate: Bazel 7 and 8.0 to 8.5 are counted, not timed", %{ctx: ctx} do
    for {name, timed} <- [{"bazel_7_6", 0}, {"bazel_8_4", 0}, {"bazel_8_6", 2}] do
      id = StreamFixture.ingest!(ctx, StreamFixture.events(name))
      records = Stream.records(id)
      assert length(records) == 15
      assert Enum.count(records, &StreamActions.timed?/1) == timed
    end
  end

  test "a restart and resent events mid-build keep every record exactly once", %{ctx: ctx} do
    events = StreamFixture.events("bazel_8_6")
    n = length(events)
    id = Replay.uuid()

    push(ctx, id, events, 1..30)
    # A resend of committed events (a client that did not see the acknowledgement).
    push(ctx, id, events, 20..30)
    GenServer.stop(worker_pid(id))
    assert reload(id).last_event_seq == 30
    # The resumed worker is sent the tail again from an earlier point.
    push(ctx, id, events, 25..n)
    push(ctx, id, events, [n - 1, n])

    assert Stream.records(id) == expected(events)
    assert reload(id).stream_actions == 15
  end

  test "a takeover by another node: the stale worker's batch writes no chunk", %{ctx: ctx_a} do
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

    events = StreamFixture.events("bazel_8_6")
    n = length(events)
    id = Replay.uuid()
    first_action = Enum.find_index(events, &match?(%{payload: {:action, _}}, &1)) + 1

    push(ctx_a, id, events, 1..first_action)
    push(ctx_b, id, events, (first_action + 1)..n)

    # Node A's worker is alive and believes the next event is its own: an action.
    next =
      Replay.ordered_event(
        StreamFixture.stream_id(id),
        first_action + 1,
        Enum.at(events, first_action)
      )

    assert {:error, {:fenced, _}} = Ingest.push_sync(ctx_a, next)

    assert Stream.records(id) == expected(events)
    assert reload(id).stream_actions == 15
  end
end
