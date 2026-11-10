defmodule Conveyor.Ingest.SessionTest do
  @moduledoc """
  The stream protocol through the session's interface: a table of scenarios, each a list of
  `{input, expected effects}` steps. No process, no database, no clock: these are the runs
  `docs/spec/Ingest.tla` explores (resend, gap, takeover, failed commit, idle exit), plus
  the ones the model leaves out (back-pressure, the writer going away, the linger).

  Inputs:

      {:push, seq, conn}          an event on connection `conn` (a control event: no payload)
      {:bep, seq, conn}           a real BEP progress event (counts towards the batch size)
      {:marker, seq, conn}        the end-of-stream marker
      {:timer, name}              the named timer elapsed
      {:commit, n} / {:fail, n, reason}    outcome of the n-th batch submitted so far
      :writer_down                the writer process went away
      {:loaded, row_opts}         the row was read (start, or after :reload)
      {:refused, reason}          the row belongs to another project
      {:lifecycle, kind}          a lifecycle notification on this node

  Effects are compared in a protocol view: `{:reply, seq | :lifecycle, result}`,
  `{:ack, conn, seq}`, `{:ack_again, conn, seq}` (a resend of a committed sequence), `{:nack, conn, seq, reason}`, `{:submit, first..last}` (or
  `{:submit, range, :final}`; `{:submit, :waiters}` for a batch that only carries a caller), `{:arm | :cancel, :flush | :linger | :refusal}`, `:reload`,
  `:unregister`, `:stop`. The idle and broadcast timers, telemetry, logs and broadcasts are
  left out unless a scenario lists them in `:also`.
  """
  use ExUnit.Case, async: true

  alias BuildEventStream, as: BES
  alias Conveyor.Bep.Replay
  alias Conveyor.Ingest.{Batch, Session}
  alias Conveyor.Ingest.Session.Config
  alias Conveyor.Invocations.Invocation
  alias Google.Devtools.Build.V1, as: V1

  @id "33333333-3333-4333-8333-333333333333"
  @stream %V1.StreamId{build_id: "b", invocation_id: @id, component: :TOOL}
  @config %Config{
    max_unacked_events: 100,
    batch_max_events: 100,
    batch_flush_ms: 50,
    idle_timeout_ms: 600_000,
    linger_ms: 30_000
  }

  scenarios = [
    # --- Push: Absorb, Flush, Commit ------------------------------------------------------
    {"events are absorbed in order, batched on the hold, acknowledged in order by the commit", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:push, 2, :c1}, [{:reply, 2, :ok}]},
       {{:timer, :flush}, [{:submit, 1..2}]},
       {{:push, 3, :c1}, [{:arm, :flush}, {:reply, 3, :ok}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:ack, :c1, 2}]},
       {{:timer, :flush}, [{:submit, 3..3}]},
       {{:commit, 2}, [{:ack, :c1, 3}]}
     ]},
    {"a batch that reaches its size is flushed without waiting for the hold",
     [config: %{@config | batch_max_events: 2}],
     [
       {{:bep, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:bep, 2, :c1}, [{:cancel, :flush}, {:submit, 1..2}, {:reply, 2, :ok}]},
       {{:timer, :flush}, []}
     ]},
    # --- Push: the dedup rule (Ingest_fixed.cfg / Ingest_current.cfg) ------------------------
    {"a resend at or below the committed sequence is acknowledged at once", [loaded: [last: 5]],
     [
       {{:push, 3, :c2}, [{:reply, 3, :ok}, {:ack_again, :c2, 3}]},
       {{:push, 5, :c2}, [{:reply, 5, :ok}, {:ack_again, :c2, 5}]},
       {{:push, 6, :c2}, [{:arm, :flush}, {:reply, 6, :ok}]}
     ]},
    {"a resend of an absorbed, unflushed event is acknowledged only by its commit, on both connections",
     [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:push, 1, :c2}, [{:reply, 1, :ok}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:ack, :c2, 1}]}
     ]},
    {"a resend of an event at the writer waits on that batch; a failed commit never acknowledges it",
     [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:push, 1, :c2}, [{:reply, 1, :ok}]},
       {{:fail, 1, "db"}, [{:nack, :c1, 1, "db"}, {:nack, :c2, 1, "db"}, :stop]}
     ]},
    # --- Push: ahead of the expected sequence ---------------------------------------------
    {"a gap with work in hand is refused", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:push, 3, :c1}, [{:reply, 3, {:error, :out_of_order}}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:push, 3, :c1}, [{:reply, 3, {:error, :out_of_order}}]}
     ]},
    {"takeover: a quiet session ahead of which the row moved resumes from the row",
     [loaded: [last: 2]],
     [
       {{:push, 6, :c1}, [:reload]},
       {{:loaded, [last: 5]},
        [{:cancel, :flush}, {:cancel, :linger}, {:arm, :flush}, {:reply, 6, :ok}]},
       {{:timer, :flush}, [{:submit, 6..6}]},
       {{:commit, 1}, [{:ack, :c1, 6}]}
     ]},
    {"takeover refused: after the reload the event is still a gap, and is judged once",
     [loaded: [last: 2]],
     [
       {{:push, 6, :c1}, [:reload]},
       {{:loaded, [last: 3]},
        [{:cancel, :flush}, {:cancel, :linger}, {:reply, 6, {:error, :out_of_order}}]},
       {{:push, 4, :c1}, [{:arm, :flush}, {:reply, 4, :ok}]}
     ]},
    {"takeover onto a row that already holds the event acknowledges it", [loaded: [last: 2]],
     [
       {{:push, 6, :c1}, [:reload]},
       {{:loaded, [last: 9]},
        [{:cancel, :flush}, {:cancel, :linger}, {:reply, 6, :ok}, {:ack_again, :c1, 6}]}
     ]},
    # --- back-pressure (not modelled) -------------------------------------------------------
    {"back-pressure: past max_unacked_events the push is answered by the next commit",
     [config: %{@config | max_unacked_events: 2}],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:push, 2, :c1}, [{:reply, 2, :ok}]},
       {{:push, 3, :c1}, []},
       {{:push, 4, :c1}, []},
       {{:timer, :flush}, [{:submit, 1..4}]},
       {{:commit, 1},
        [
          {:ack, :c1, 1},
          {:ack, :c1, 2},
          {:ack, :c1, 3},
          {:ack, :c1, 4},
          {:reply, 4, :ok},
          {:reply, 3, :ok}
        ]}
     ]},
    {"back-pressure: a failed batch answers the blocked callers too",
     [config: %{@config | max_unacked_events: 1}],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:push, 2, :c1}, []},
       {{:timer, :flush}, [{:submit, 1..2}]},
       {{:fail, 1, {:fenced, 0}},
        [
          {:nack, :c1, 1, {:fenced, 0}},
          {:nack, :c1, 2, {:fenced, 0}},
          {:reply, 2, {:error, {:fenced, 0}}},
          :stop
        ]}
     ]},
    # --- Commit fenced / DbFail: every waiter hears ---------------------------------------
    {"a failed batch fails every batch behind it and the open one, in sequence order", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:push, 2, :c2}, [{:arm, :flush}, {:reply, 2, :ok}]},
       {{:timer, :flush}, [{:submit, 2..2}]},
       {{:push, 3, :c2}, [{:arm, :flush}, {:reply, 3, :ok}]},
       {{:fail, 1, {:fenced, 0}},
        [
          {:nack, :c1, 1, {:fenced, 0}},
          {:nack, :c2, 2, {:fenced, 0}},
          {:nack, :c2, 3, {:fenced, 0}},
          :stop
        ]}
     ]},
    {"an expired batch is a failed batch: its waiters hear the reason and the session stops", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:fail, 1, :expired}, [{:nack, :c1, 1, :expired}, :stop]}
     ]},
    # --- the writer goes away: outcome unknown ----------------------------------------------
    {"a writer that goes away with batches in hand fails the stream", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:marker, 2, :c1}, [{:submit, 2..2, :final}, {:reply, 2, :ok}]},
       {:writer_down, [{:nack, :c1, 1, :writer_down}, {:nack, :c1, 2, :writer_down}, :stop]}
     ]},
    {"a writer that goes away while the session holds nothing at it changes nothing", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {:writer_down, []},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:commit, 1}, [{:ack, :c1, 1}]}
     ]},
    {"outcome unknown, the batch did commit: the next session acknowledges the resend from the row",
     [loaded: [last: 2]],
     [
       {{:push, 1, :c2}, [{:reply, 1, :ok}, {:ack_again, :c2, 1}]},
       {{:push, 2, :c2}, [{:reply, 2, :ok}, {:ack_again, :c2, 2}]},
       {{:push, 3, :c2}, [{:arm, :flush}, {:reply, 3, :ok}]}
     ]},
    {"outcome unknown, the batch did not commit: the next session absorbs the resend",
     [loaded: [last: 0]],
     [
       {{:push, 1, :c2}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:push, 2, :c2}, [{:reply, 2, :ok}]}
     ]},
    # --- the end of the stream ------------------------------------------------------------
    {"the marker flushes at once, finalizes in its batch, and the session lingers then exits", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:marker, 2, :c1}, [{:cancel, :flush}, {:submit, 1..2, :final}, {:reply, 2, :ok}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:ack, :c1, 2}, {:arm, :linger}]},
       {{:push, 2, :c2}, [{:reply, 2, :ok}, {:ack_again, :c2, 2}]},
       {{:timer, :idle}, []},
       {{:timer, :linger}, [:stop]}
     ]},
    {"finalize once: a lifecycle finish while the final batch is at the writer does not finalize again",
     [],
     [
       {{:marker, 1, :c1}, [{:submit, 1..1, :final}, {:reply, 1, :ok}]},
       {{:lifecycle, :invocation_attempt_finished}, [{:submit, :waiters}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:arm, :linger}]},
       {{:commit, 2}, [{:reply, :lifecycle, :ok}]},
       {{:commit, 2}, []}
     ]},
    {"a lifecycle finish is committed through the fence; fenced, the caller is told", [],
     [
       {{:lifecycle, :invocation_attempt_started}, [{:reply, :lifecycle, :ok}]},
       {{:lifecycle, :invocation_attempt_finished}, [{:submit, :waiters}]},
       {{:fail, 1, {:fenced, 0}}, [{:reply, :lifecycle, {:error, {:fenced, 0}}}, :stop]}
     ]},
    {"a session for a finished build only lingers and answers resends",
     [loaded: [last: 4, finished: true]],
     [
       {{:push, 4, :c1}, [{:reply, 4, :ok}, {:ack_again, :c1, 4}]},
       {{:timer, :idle}, []},
       {{:timer, :linger}, [:stop]}
     ]},
    # --- Exit: only when quiet ----------------------------------------------------------------
    {"a linger that elapses with a batch at the writer waits for its outcome", [],
     [
       {{:marker, 1, :c1}, [{:submit, 1..1, :final}, {:reply, 1, :ok}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:arm, :linger}]},
       {{:lifecycle, :invocation_attempt_finished}, [{:submit, :waiters}]},
       {{:timer, :linger}, []},
       {{:commit, 2}, [{:reply, :lifecycle, :ok}, :stop]}
     ]},
    # --- idle disconnect and resume ---------------------------------------------------------
    {"idle: the build is marked disconnected through the fence, then the session lingers", [],
     [
       {{:push, 1, :c1}, [{:arm, :idle}, {:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :flush}, [{:submit, 1..1}]},
       {{:timer, :idle}, [{:arm, :idle}]},
       {{:commit, 1}, [{:ack, :c1, 1}]},
       {{:timer, :idle}, [{:submit, :disconnect}]},
       {{:timer, :idle}, [{:arm, :idle}]},
       {{:commit, 2}, [{:arm, :linger}]},
       {{:timer, :linger}, [:stop]}
     ], [also: [:idle]]},
    {"idle with events still buffered: they go out with the disconnect", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :idle}, [{:cancel, :flush}, {:submit, 1..1, :final}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:arm, :linger}]}
     ]},
    {"a client back within the linger resumes from the row: the linger is cancelled and the marker finalizes",
     [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :idle}, [{:cancel, :flush}, {:submit, 1..1, :final}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:arm, :linger}]},
       {{:push, 2, :c2}, [:reload]},
       {{:loaded, [last: 1, status: "disconnected"]},
        [{:cancel, :flush}, {:cancel, :linger}, {:arm, :flush}, {:reply, 2, :ok}]},
       {{:marker, 3, :c2}, [{:cancel, :flush}, {:submit, 2..3, :final}, {:reply, 3, :ok}]},
       {{:commit, 2}, [{:ack, :c2, 2}, {:ack, :c2, 3}, {:arm, :linger}]},
       {{:timer, :linger}, [:stop]}
     ]},
    {"a client back before the disconnect committed keeps the session live: no linger, the marker finalizes",
     [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :idle}, [{:cancel, :flush}, {:submit, 1..1, :final}]},
       {{:push, 2, :c1}, [{:arm, :flush}, {:reply, 2, :ok}]},
       {{:commit, 1}, [{:ack, :c1, 1}]},
       {{:marker, 3, :c1}, [{:cancel, :flush}, {:submit, 2..3, :final}, {:reply, 3, :ok}]},
       {{:commit, 2}, [{:ack, :c1, 2}, {:ack, :c1, 3}, {:arm, :linger}]}
     ]},
    {"a resend to a disconnected session does not resume it", [],
     [
       {{:push, 1, :c1}, [{:arm, :flush}, {:reply, 1, :ok}]},
       {{:timer, :idle}, [{:cancel, :flush}, {:submit, 1..1, :final}]},
       {{:commit, 1}, [{:ack, :c1, 1}, {:arm, :linger}]},
       {{:push, 1, :c2}, [{:reply, 1, :ok}, {:ack_again, :c2, 1}]},
       {{:timer, :linger}, [:stop]}
     ]},
    # --- tenancy ------------------------------------------------------------------------------
    {"a row of another project refuses the session: it gives its name up, answers and goes",
     [loaded: :skip],
     [
       {{:refused, :not_found}, [:unregister, {:arm, :refusal}]},
       {{:push, 1, :c1}, [{:reply, 1, {:error, :not_found}}, {:arm, :refusal}]},
       {{:lifecycle, :invocation_attempt_finished},
        [{:reply, :lifecycle, {:error, :not_found}}, {:arm, :refusal}]},
       {{:timer, :broadcast}, []},
       {{:timer, :refusal}, [:stop]}
     ]}
  ]

  for {name, opts, steps} <-
        Enum.map(scenarios, fn
          {name, opts, steps} -> {name, opts ++ [also: []], steps}
          {name, opts, steps, more} -> {name, opts ++ more, steps}
        end) do
    @tag opts: opts, steps: steps
    test name, %{opts: opts, steps: steps} do
      session =
        Session.new(Keyword.get(opts, :config, @config), invocation_id: @id, project_id: 1)

      session =
        case Keyword.get(opts, :loaded, []) do
          :skip -> session
          row -> session |> Session.loaded({:ok, row(row)}) |> elem(0)
        end

      Enum.reduce(Enum.with_index(steps, 1), {session, []}, fn {{input, expected}, n},
                                                               {session, submitted} ->
        {session, effects} = apply_input(session, input, submitted)
        submitted = submitted ++ for {:submit, %Batch{ref: ref}} <- effects, do: ref

        assert view(effects, opts[:also]) == expected,
               "step #{n} #{inspect(input)}: got #{inspect(view(effects, opts[:also]))}"

        {session, submitted}
      end)
    end
  end

  defp row(opts) do
    %Invocation{
      id: @id,
      project_id: 1,
      last_event_seq: Keyword.get(opts, :last, 0),
      stream_finished: Keyword.get(opts, :finished, false),
      status: Keyword.get(opts, :status, "in_progress"),
      tags: Keyword.get(opts, :tags, %{}),
      started_at: ~U[2026-11-09 10:00:00.000000Z],
      inserted_at: ~U[2026-11-09 10:00:00.000000Z]
    }
  end

  defp control(seq),
    do:
      Replay.ordered_event(
        @stream,
        seq,
        {:console_output,
         %V1.BuildEvent.ConsoleOutput{type: :STDERR, output: {:text_output, "x"}}}
      )

  defp progress(seq, text \\ "line\n") do
    Replay.ordered_event(@stream, seq, %BES.BuildEvent{
      id: %BES.BuildEventId{id: {:progress, %BES.BuildEventId.ProgressId{opaque_count: seq}}},
      payload: {:progress, %BES.Progress{stderr: text}}
    })
  end

  defp marker(seq),
    do:
      Replay.ordered_event(
        @stream,
        seq,
        {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}
      )

  defp apply_input(s, {:push, seq, conn}, _), do: Session.push(s, control(seq), conn, {conn, seq})
  defp apply_input(s, {:bep, seq, conn}, _), do: Session.push(s, progress(seq), conn, {conn, seq})

  defp apply_input(s, {:marker, seq, conn}, _),
    do: Session.push(s, marker(seq), conn, {conn, seq})

  defp apply_input(s, {:timer, name}, _), do: Session.timer(s, name)
  defp apply_input(s, {:commit, n}, refs), do: Session.committed(s, Enum.at(refs, n - 1))

  defp apply_input(s, {:fail, n, reason}, refs),
    do: Session.failed(s, Enum.at(refs, n - 1), reason)

  defp apply_input(s, :writer_down, _), do: Session.writer_down(s)
  defp apply_input(s, {:loaded, row}, _), do: Session.loaded(s, {:ok, row(row)})
  defp apply_input(s, {:refused, reason}, _), do: Session.loaded(s, {:error, reason})
  defp apply_input(s, {:lifecycle, kind}, _), do: Session.lifecycle(s, kind, {:lifecycle, kind})

  defp view(effects, also) do
    Enum.flat_map(effects, fn
      {:reply, {:lifecycle, _kind}, result} ->
        [{:reply, :lifecycle, result}]

      {:reply, {_conn, seq}, result} ->
        [{:reply, seq, result}]

      {:ack, _, _} = ack ->
        [ack]

      {:ack_again, _, _} = ack ->
        [ack]

      {:nack, _, _, _} = nack ->
        [nack]

      {:submit, %Batch{finalize: true} = b} when b.last_seq < b.first_seq ->
        [{:submit, :disconnect}]

      {:submit, %Batch{finalize: true} = b} ->
        [{:submit, b.first_seq..b.last_seq//1, :final}]

      {:submit, %Batch{} = b} when b.last_seq < b.first_seq ->
        [{:submit, :waiters}]

      {:submit, %Batch{} = b} ->
        [{:submit, b.first_seq..b.last_seq//1}]

      {:arm, name, _ms} when name in [:flush, :linger, :refusal] ->
        [{:arm, name}]

      {:cancel, name} when name in [:flush, :linger] ->
        [{:cancel, name}]

      {:arm, name, _ms} ->
        if name in also, do: [{:arm, name}], else: []

      {:stop, :normal} ->
        [:stop]

      effect when effect in [:reload, :unregister] ->
        [effect]

      _ ->
        []
    end)
  end

  # --- what the table's protocol view leaves out -------------------------------------------

  defp live(row_opts \\ []) do
    {s, _} =
      @config
      |> Session.new(invocation_id: @id, project_id: 1)
      |> Session.loaded({:ok, row(row_opts)})

    s
  end

  test "the final batch carries the final status and counts the tags once" do
    s = live(tags: %{"team" => "core"})
    {s, _} = Session.push(s, progress(1), :c1, {:c1, 1})
    {s, fx} = Session.push(s, marker(2), :c1, {:c1, 2})
    assert [%Batch{finalize: true} = final] = for({:submit, b} <- fx, do: b)
    assert %{stream_finished: true, status: status, finished_at: %DateTime{}} = final.invocation
    assert is_binary(status) and status != "in_progress"
    assert final.tag_keys[{"team", "core"}] == 1
    assert Batch.event_count(final) == 1

    # A lifecycle finish while that batch is at the writer: an update of one column.
    {_s, fx} = Session.lifecycle(s, :invocation_attempt_finished, {:lifecycle, 1})

    assert [%Batch{finalize: false, tag_keys: tags, invocation: inv}] =
             for({:submit, b} <- fx, do: b)

    assert tags == %{} and inv == %{lifecycle_finished: true}
  end

  test "an idle disconnect writes the status, not the end of the stream" do
    {_s, fx} = Session.timer(live(), :idle)
    assert [%Batch{finalize: true, invocation: inv}] = for({:submit, b} <- fx, do: b)
    assert %{status: "disconnected", finished_at: %DateTime{}} = inv
    refute Map.has_key?(inv, :stream_finished)
    assert Enum.any?(fx, &match?({:log, :info, "invocation " <> _}, &1))
  end

  test "a commit reports its events; a failure and a gap are logged" do
    s = live()
    {s, _} = Session.push(s, progress(1), :c1, {:c1, 1})
    {s, fx} = Session.push(s, control(5), :c1, {:c1, 5})
    assert Enum.any?(fx, &match?({:log, :warning, _}, &1))
    {s, [{:submit, batch}]} = Session.timer(s, :flush)
    {s2, fx} = Session.committed(s, batch.ref)

    assert {:telemetry, [:conveyor, :ingest, :batch, :committed], %{events: 1},
            %{invocation_id: @id}} in fx

    assert Session.summary(s2).last_event_seq == 1
    {_s, fx} = Session.failed(s, batch.ref, "db")
    assert Enum.any?(fx, &match?({:log, :error, _}, &1))
  end

  test "every push re-arms the idle timer; an undecodable event is acknowledged and logged" do
    bad =
      Replay.ordered_event(
        @stream,
        1,
        {:bazel_event,
         %Google.Protobuf.Any{
           type_url: "type.googleapis.com/build_event_stream.BuildEvent",
           value: <<0xFF, 0xFF>>
         }}
      )

    {s, fx} = Session.push(live(), bad, :c1, {:c1, 1})
    assert {:arm, :idle, 600_000} in fx and {:reply, {:c1, 1}, :ok} in fx
    assert Enum.any?(fx, &match?({:log, :warning, _}, &1))
    {_s, [{:submit, batch}]} = Session.timer(s, :flush)
    assert batch.last_seq == 1 and Batch.event_count(batch) == 0
  end

  test "digests: one tick publishes what changed, a quiet tick hibernates, a finished session slims" do
    s = live()
    {s, fx} = Session.push(s, progress(1, "hello\n"), :c1, {:c1, 1})
    # Loading already armed the tick (the build is visible at once); nothing is armed twice.
    refute Enum.any?(fx, &match?({:arm, :broadcast, _}, &1))

    {s, fx} = Session.timer(s, :broadcast)
    topics = for {:broadcast, topic, _} <- fx, do: topic

    assert topics == [
             "project:1:invocations",
             "invocations:all",
             "invocation:#{@id}",
             "invocation:#{@id}:log"
           ]

    assert {:broadcast, _, {:log_chunks, ["hello\n"], 0}} = List.last(fx)
    assert {:broadcast, _, {:invocation_updated, listed}} = hd(fx)
    refute Map.has_key?(listed, :options)
    # Work in hand: no hibernation.
    refute :hibernate in fx

    {s, fx} = Session.push(s, marker(2), :c1, {:c1, 2})
    [final] = for {:submit, b} <- fx, do: b
    # The commit makes the build final: that is worth a tick.
    {s, fx} = Session.committed(s, final.ref)
    assert {:arm, :broadcast, 250} in fx
    {s, fx} = Session.timer(s, :broadcast)
    assert :hibernate in fx
    assert %{finalized: true} = summary = Session.summary(s)
    refute Map.has_key?(summary, :options)

    # Nothing changed since: a tick publishes nothing.
    {_s, fx} = Session.timer(s, :broadcast)
    assert fx == [:hibernate]
  end

  test "the commit that leaves a finished session quiet compacts it; a live one is left alone" do
    s = live()
    {s, _fx} = Session.push(s, progress(1, "hello\n"), :c1, {:c1, 1})
    {s, fx} = Session.timer(s, :flush)
    [batch] = for {:submit, b} <- fx, do: b
    {s, fx} = Session.committed(s, batch.ref)
    refute :hibernate in fx

    {s, fx} = Session.push(s, marker(2), :c1, {:c1, 2})
    [final] = for {:submit, b} <- fx, do: b
    {s, fx} = Session.committed(s, final.ref)
    assert :hibernate in fx

    # The attempt-finished notification wakes the lingering session; its commit puts it
    # back, whether or not a broadcast tick is still to come.
    {s, fx} = Session.lifecycle(s, :invocation_attempt_finished, {:c2, 1})
    [notified] = for {:submit, b} <- fx, do: b
    {_s, fx} = Session.committed(s, notified.ref)
    assert {:reply, {:c2, 1}, :ok} in fx
    assert :hibernate in fx
  end

  test "a referenced profile: a local file is settled in the final batch, a remote one is scheduled" do
    final = fn uri ->
      s = live()
      s = put_in(s.norm.inv[:profile_status], "referenced")
      s = put_in(s.norm.inv[:profile_uri], uri)
      {s, fx} = Session.push(s, marker(1), :c1, {:c1, 1})
      [batch] = for {:submit, b} <- fx, do: b
      {batch, fx, Session.committed(s, batch.ref) |> elem(1)}
    end

    {batch, fx, after_commit} = final.("file:///tmp/profile.gz")
    assert batch.invocation.profile_status == "unavailable"
    assert Enum.any?(fx, &match?({:log, :info, _}, &1))
    refute Enum.any?(after_commit, &match?({:finalized, _}, &1))

    {_batch, _fx, after_commit} =
      final.("bytestream://cache.example:443/blobs/#{String.duplicate("a", 64)}/10")

    assert Enum.any?(after_commit, &match?({:finalized, %{profile_status: "referenced"}}, &1))
  end
end
