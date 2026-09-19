defmodule Conveyor.Ingest.Worker do
  @moduledoc """
  One process per live invocation. Owns sequence ordering and deduplication, runs the
  normalizer, accumulates batches, hands them to the writer shard, releases acks when
  commits land, publishes coalesced PubSub digests, and finalizes the invocation when the
  stream ends or goes idle.

  State lives in Postgres: on start the worker rehydrates from the invocation row, so a
  restart (or a takeover on another node) resumes from the last committed sequence.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Conveyor.Bep.Event
  alias Conveyor.Ingest
  alias Conveyor.Ingest.{Batch, Normalizer, Retry, Scrub, WriterPool}
  alias Conveyor.Invocations
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo
  alias Google.Devtools.Build.V1, as: V1

  def start_link({ctx, invocation_id, stream_id}) do
    GenServer.start_link(__MODULE__, {ctx, invocation_id, stream_id}, name: via(invocation_id))
  end

  def via(invocation_id), do: {:via, Registry, {Conveyor.Ingest.Registry, invocation_id}}

  @doc "Current in-memory summary of the invocation (for tests and debugging)."
  def summary(invocation_id), do: GenServer.call(via(invocation_id), :summary)

  # --- init ---------------------------------------------------------------------------------

  @impl true
  def init({ctx, invocation_id, stream_id}) do
    Process.flag(:trap_exit, false)
    {:ok, %{ctx: ctx, invocation_id: invocation_id, stream_id: stream_id}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %{ctx: ctx, invocation_id: id, stream_id: stream_id}) do
    inv =
      Retry.with_backoff(fn -> load_or_create!(ctx, id, stream_id) end,
        label: "worker load #{id}"
      )

    norm =
      Normalizer.new(inv,
        keywords: ctx.keywords,
        api_key_tags: ctx.api_key_tags,
        max_log_bytes: (ctx.limits || Conveyor.Limits.defaults()).max_log_bytes
      )

    day = Invocations.day(inv)

    state = %{
      ctx: ctx,
      invocation_id: id,
      day: day,
      norm: norm,
      expected_seq: inv.last_event_seq + 1,
      batch:
        Batch.new(id, ctx.project_id, day, inv.last_event_seq + 1, inv.log_bytes, inv.log_lines),
      inflight: %{},
      blocked: [],
      committed_seq: inv.last_event_seq,
      flush_timer: nil,
      idle_timer: nil,
      broadcast_timer: nil,
      dirty: fresh_dirty(),
      stream_finished: inv.stream_finished,
      lifecycle_finished: inv.lifecycle_finished,
      finalized: inv.stream_finished,
      lingering: false,
      last_event_at: System.monotonic_time(:millisecond)
    }

    # A worker started for an already finished build (a late duplicate after a restart)
    # only needs to answer what arrives during the linger window.
    state = if state.finalized, do: start_linger(state), else: state
    {:noreply, state |> reset_idle() |> mark_dirty(:summary) |> schedule_broadcast()}
  end

  defp load_or_create!(ctx, id, stream_id) do
    case Repo.get(Invocation, id) do
      %Invocation{} = inv ->
        inv

      nil ->
        now = DateTime.utc_now()

        %Invocation{
          id: id,
          project_id: ctx.project_id,
          api_key_id: ctx.api_key_id,
          build_id: blank_to_nil(stream_id && stream_id.build_id),
          bes_instance_name: ctx.instance_name,
          keywords: ctx.keywords,
          started_at: now,
          last_event_at: now,
          tags:
            Conveyor.Ingest.Tags.merge(%{
              keywords: Conveyor.Ingest.Tags.from_keywords(ctx.keywords),
              api_key: ctx.api_key_tags
            })
        }
        |> Repo.insert!(on_conflict: :nothing, conflict_target: :id)
        |> then(fn _ -> Repo.get!(Invocation, id) end)
    end
  end

  # --- calls --------------------------------------------------------------------------------

  # `acker` receives `{:ack, seq}` once the event is committed (or `{:ack_failed, seq, reason}`).
  # The call itself returns as soon as the event is absorbed, so the gRPC handler keeps
  # reading; when too much is unacknowledged the reply is deferred until the next commit,
  # which is the backpressure that eventually slows Bazel down through HTTP/2 flow control.
  @impl true
  def handle_call({:push, %V1.OrderedBuildEvent{sequence_number: seq} = obe, acker}, from, state) do
    state = %{state | last_event_at: System.monotonic_time(:millisecond)} |> reset_idle()

    cond do
      seq < state.expected_seq ->
        # Already committed (client resend after a retry): ack immediately.
        send(acker, {:ack, seq})
        {:reply, :ok, state}

      seq > state.expected_seq ->
        Logger.warning(
          "invocation #{state.invocation_id}: got seq #{seq}, expected #{state.expected_seq}"
        )

        {:reply, {:error, :out_of_order}, state}

      true ->
        state = absorb(state, obe)

        state = %{
          state
          | expected_seq: seq + 1,
            batch: Batch.add_waiter(state.batch, {:ack, acker}, seq)
        }

        state = maybe_flush(state)

        if unacked(state) > Ingest.config(:max_unacked_events, 2_000) do
          {:noreply, %{state | blocked: [from | state.blocked]}}
        else
          {:reply, :ok, state}
        end
    end
  end

  def handle_call({:lifecycle, :invocation_attempt_started, _obe}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:lifecycle, :invocation_attempt_finished, _obe}, from, state) do
    state = %{state | lifecycle_finished: true}
    state = update_in(state.norm, &Normalizer.set(&1, %{lifecycle_finished: true}))
    state = %{state | batch: Batch.add_waiter(state.batch, {:reply, from}, nil)}
    {:noreply, flush(state)}
  end

  def handle_call(:summary, _from, state), do: {:reply, summary(state.norm, state), state}

  # --- absorbing one event ---------------------------------------------------------------

  defp absorb(state, %V1.OrderedBuildEvent{sequence_number: seq, event: event}) do
    case Event.bes_kind(event) do
      :bazel_event ->
        case Event.unwrap(event) do
          {:ok, bep} ->
            {bep, changed?} = Scrub.event(bep)

            bytes =
              if changed?, do: BuildEventStream.BuildEvent.encode(bep), else: any_bytes(event)

            kind = bep |> Event.payload_kind() |> to_string()
            {norm, batch} = Normalizer.apply(state.norm, bep, seq, state.batch)
            batch = Batch.add_event(batch, seq, kind, bytes)
            %{state | norm: norm, batch: batch} |> mark_dirty_for(bep)

          {:error, reason} ->
            Logger.warning(
              "invocation #{state.invocation_id} ##{seq}: undecodable bazel_event #{inspect(reason)}"
            )

            %{state | batch: Batch.add_marker(state.batch, seq)}
        end

      :component_stream_finished ->
        %{state | stream_finished: true, batch: Batch.add_marker(state.batch, seq)}

      _other ->
        %{state | batch: Batch.add_marker(state.batch, seq)}
    end
  end

  defp any_bytes(%V1.BuildEvent{event: {:bazel_event, %Google.Protobuf.Any{value: bytes}}}),
    do: bytes

  # --- batching and commits ---------------------------------------------------------------

  defp maybe_flush(state) do
    cond do
      Batch.event_count(state.batch) >= Ingest.config(:batch_max_events, 500) ->
        flush(state)

      state.batch.event_bytes + state.batch.log_bytes >=
          Ingest.config(:batch_max_bytes, 256 * 1024) ->
        flush(state)

      state.stream_finished ->
        flush(state)

      state.flush_timer == nil ->
        %{
          state
          | flush_timer: Process.send_after(self(), :flush, Ingest.config(:batch_flush_ms, 50))
        }

      true ->
        state
    end
  end

  defp flush(state) do
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    state = %{state | flush_timer: nil}

    {norm, batch} = prepare(state)

    if Batch.empty?(batch) and batch.waiters == [] do
      %{state | norm: norm}
    else
      WriterPool.for_invocation(state.invocation_id) |> Conveyor.Ingest.Writer.submit(batch)

      next =
        Batch.new(
          state.invocation_id,
          state.ctx.project_id,
          state.day,
          state.expected_seq,
          norm.inv[:log_bytes],
          norm.inv[:log_lines]
        )

      %{state | norm: norm, batch: next, inflight: Map.put(state.inflight, batch.ref, batch)}
    end
  end

  # Finalization happens in the batch that carries the end-of-stream marker, so the final
  # status and the last ack become durable together.
  defp prepare(%{stream_finished: true, finalized: false} = state) do
    norm = Normalizer.finalize(state.norm)
    {changes, norm} = Normalizer.take_dirty(norm)

    batch =
      state.batch
      |> Batch.set_invocation(changes)
      |> Batch.count_tags(norm.inv[:tags])
      |> Map.put(:finalize, true)

    {norm, batch}
  end

  defp prepare(state) do
    {changes, norm} = Normalizer.take_dirty(state.norm)
    {norm, Batch.set_invocation(state.batch, changes)}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}

  def handle_info({:batch_committed, ref}, state) do
    {batch, inflight} = Map.pop(state.inflight, ref)
    notify_waiters(batch, :ok)

    :telemetry.execute(
      [:conveyor, :ingest, :batch, :committed],
      %{events: Batch.event_count(batch)},
      %{invocation_id: state.invocation_id}
    )

    state =
      %{state | inflight: inflight, committed_seq: max(state.committed_seq, batch.last_seq)}
      |> unblock()

    state =
      if batch.finalize do
        Conveyor.Artifacts.on_finalized(state.invocation_id)
        %{state | finalized: true} |> mark_dirty(:summary) |> start_linger()
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:batch_failed, ref, reason}, state) do
    {batch, _} = Map.pop(state.inflight, ref)
    notify_waiters(batch, {:error, reason})
    Enum.each(state.blocked, &GenServer.reply(&1, {:error, reason}))
    Logger.error("invocation #{state.invocation_id}: batch commit failed: #{inspect(reason)}")
    {:stop, :normal, %{state | inflight: %{}, blocked: []}}
  end

  def handle_info(:idle_timeout, state) do
    if state.finalized or state.inflight != %{} do
      {:noreply, reset_idle(state)}
    else
      Logger.info(
        "invocation #{state.invocation_id}: idle for #{Ingest.config(:idle_timeout_ms)} ms, marking disconnected"
      )

      norm = Normalizer.disconnect(state.norm)
      {changes, norm} = Normalizer.take_dirty(norm)
      batch = state.batch |> Batch.set_invocation(changes) |> Map.put(:finalize, true)
      WriterPool.for_invocation(state.invocation_id) |> Conveyor.Ingest.Writer.submit(batch)

      next =
        Batch.new(
          state.invocation_id,
          state.ctx.project_id,
          state.day,
          state.expected_seq,
          norm.inv[:log_bytes],
          norm.inv[:log_lines]
        )

      {:noreply,
       %{
         state
         | norm: norm,
           batch: next,
           inflight: Map.put(state.inflight, batch.ref, batch),
           stream_finished: true
       }}
    end
  end

  def handle_info(:linger_expired, state), do: {:stop, :normal, state}

  def handle_info(:broadcast, state),
    do: {:noreply, state |> Map.put(:broadcast_timer, nil) |> broadcast()}

  # Waiters are stored newest-first; acks must go out in ascending sequence order.
  defp notify_waiters(%Batch{waiters: waiters}, reply) do
    waiters
    |> Enum.reverse()
    |> Enum.each(fn
      {{:reply, from}, _seq} -> GenServer.reply(from, reply)
      {{:ack, pid}, seq} when reply == :ok -> send(pid, {:ack, seq})
      {{:ack, pid}, seq} -> send(pid, {:ack_failed, seq, elem(reply, 1)})
    end)
  end

  defp unacked(state), do: state.expected_seq - 1 - state.committed_seq

  defp unblock(%{blocked: []} = state), do: state

  defp unblock(state) do
    Enum.each(state.blocked, &GenServer.reply(&1, :ok))
    %{state | blocked: []}
  end

  # --- timers -------------------------------------------------------------------------------

  defp reset_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)

    %{
      state
      | idle_timer:
          Process.send_after(self(), :idle_timeout, Ingest.config(:idle_timeout_ms, 600_000))
    }
  end

  defp start_linger(%{lingering: true} = state), do: state

  defp start_linger(state) do
    Process.send_after(self(), :linger_expired, Ingest.config(:linger_ms, 30_000))
    %{state | lingering: true}
  end

  # --- broadcasts ---------------------------------------------------------------------------

  defp fresh_dirty, do: %{summary: false, targets: %{}, tests: %{}, actions: [], log: []}

  defp mark_dirty(state, :summary),
    do: %{state | dirty: %{state.dirty | summary: true}} |> schedule_broadcast()

  defp mark_dirty_for(state, %BuildEventStream.BuildEvent{payload: {kind, _}} = bep) do
    dirty = state.dirty

    dirty =
      case kind do
        :progress ->
          {:progress, p} = bep.payload
          %{dirty | log: [p.stdout <> p.stderr | dirty.log]}

        k when k in [:configured, :completed, :test_summary, :target_summary] ->
          %{dirty | targets: Map.merge(dirty.targets, state.batch.targets), summary: true}

        :test_result ->
          %{dirty | tests: Map.merge(dirty.tests, state.batch.tests), summary: true}

        :action ->
          %{dirty | actions: Enum.take(state.batch.actions, 1) ++ dirty.actions, summary: true}

        _ ->
          %{dirty | summary: true}
      end

    %{state | dirty: dirty} |> schedule_broadcast()
  end

  defp schedule_broadcast(%{broadcast_timer: nil} = state) do
    %{
      state
      | broadcast_timer:
          Process.send_after(self(), :broadcast, Ingest.config(:broadcast_interval_ms, 250))
    }
  end

  defp schedule_broadcast(state), do: state

  defp broadcast(%{dirty: dirty} = state) do
    id = state.invocation_id
    project_id = state.ctx.project_id

    if dirty.summary do
      summary = summary(state.norm, state)

      Phoenix.PubSub.broadcast(
        Conveyor.PubSub,
        Ingest.project_topic(project_id),
        {:invocation_updated, summary}
      )

      Phoenix.PubSub.broadcast(
        Conveyor.PubSub,
        Ingest.all_topic(),
        {:invocation_updated, summary}
      )
    end

    if dirty.summary or dirty.targets != %{} or dirty.tests != %{} or dirty.actions != [] do
      detail = %{
        invocation: summary(state.norm, state),
        targets: Map.values(dirty.targets),
        tests: Map.values(dirty.tests),
        actions: Enum.reverse(dirty.actions)
      }

      Phoenix.PubSub.broadcast(
        Conveyor.PubSub,
        Ingest.invocation_topic(id),
        {:invocation_detail, detail}
      )
    end

    if dirty.log != [] do
      Phoenix.PubSub.broadcast(
        Conveyor.PubSub,
        Ingest.log_topic(id),
        {:log_chunks, Enum.reverse(dirty.log)}
      )
    end

    %{state | dirty: fresh_dirty()}
  end

  defp summary(norm, state) do
    norm.inv
    |> Map.put(:id, state.invocation_id)
    |> Map.put(:project_id, state.ctx.project_id)
    |> Map.put(:last_event_seq, state.expected_seq - 1)
    |> Map.put(:finalized, state.finalized)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
