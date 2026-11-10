defmodule Conveyor.Ingest.Worker do
  @moduledoc """
  One process per live invocation: the wiring around `Conveyor.Ingest.Session`. The session
  module holds the protocol (order, dedup, batches, back-pressure, idle, linger, finalize)
  as pure transitions; this process turns messages into its inputs and carries its effects
  out: replies, acks to the connection's acker, batches to the writer shard, timers, the
  row, PubSub, telemetry, logs.

  What the process adds to the session's interface:

    * **The row.** `load_or_create/3` reads or creates the invocation row, on start and for
      every `:reload`; it is also where the tenancy rule lives. State lives in Postgres, so
      a restart (or a takeover on another node) resumes from the last committed sequence.
    * **Commit delivery.** A submitted batch always gets an outcome: the writer's
      `{:batch_committed, ref}` or `{:batch_failed, ref, reason}`, or, when the writer
      process goes away, the monitor's `:DOWN`, fed to the session as `writer_down/1`
      (see `Conveyor.Ingest.Writer.submit/2`).
    * **Timers.** Named timers armed and cancelled by effects; a timer that fires after it
      was replaced or cancelled is dropped here and never reaches the session.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Conveyor.Ingest
  alias Conveyor.Ingest.{Retry, Session, Writer, WriterPool}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo
  alias Conveyor.Watch
  alias Google.Devtools.Build.V1, as: V1

  def start_link({ctx, invocation_id, stream_id}) do
    GenServer.start_link(__MODULE__, {ctx, invocation_id, stream_id},
      name: via(ctx.registry, ctx.project_id, invocation_id)
    )
  end

  # A worker is registered under its project and invocation id: a context of another
  # project never reaches it, and the worker that context starts instead is refused by
  # `load_or_create/3` without disturbing the owner's stream.
  def via(registry \\ Conveyor.Ingest.Registry, project_id, invocation_id),
    do: {:via, Registry, {registry, {project_id, invocation_id}}}

  @doc "The live worker of a project's invocation on this node, or nil."
  @spec whereis(atom(), term(), String.t()) :: pid() | nil
  def whereis(registry \\ Conveyor.Ingest.Registry, project_id, invocation_id) do
    case Registry.lookup(registry, {project_id, invocation_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Current in-memory summary of the invocation (for tests and debugging)."
  def summary(project_id, invocation_id),
    do: GenServer.call(via(project_id, invocation_id), :summary)

  # --- the row ------------------------------------------------------------------------------

  # Insert first: a new build costs one statement; only a resumed or concurrently created
  # invocation (conflict) needs the read. Schema defaults match the column defaults.
  @doc """
  The invocation row for a stream, created on first sight. Used by the worker on load and
  by `Conveyor.Ingest.lifecycle/2` for the attempt-started notification, which must never
  start a worker (behind a balancer the notification and the stream land on different
  nodes; a worker started here would only fence the real one).

  This is the one place every write path of a stream crosses before it may touch a build,
  so the tenancy rule lives here: a row that exists under another project is
  `{:error, :not_found}` for this context and nothing is written. Raises on database
  errors.
  """
  @spec load_or_create(Conveyor.Ingest.Context.t(), String.t(), V1.StreamId.t() | nil) ::
          {:ok, Invocation.t()} | {:error, :not_found}
  def load_or_create(ctx, id, stream_id) do
    now = DateTime.utc_now()

    row =
      %Invocation{
        id: id,
        project_id: ctx.project_id,
        api_key_id: ctx.api_key_id,
        build_id: blank_to_nil(stream_id && stream_id.build_id),
        bes_instance_name: ctx.instance_name,
        keywords: ctx.keywords,
        started_at: now,
        last_event_at: now,
        inserted_at: now,
        updated_at: now,
        tags:
          Conveyor.Ingest.Tags.merge(%{
            keywords: Conveyor.Ingest.Tags.from_keywords(ctx.keywords),
            api_key: ctx.api_key_tags
          })
      }
      |> Map.from_struct()
      |> Map.take(Invocation.__schema__(:fields))

    fields = Invocation.__schema__(:fields)
    cols = Enum.map_join(fields, ", ", &~s("#{&1}"))
    placeholders = Enum.map_join(1..length(fields), ", ", &"$#{&1}")

    params =
      Enum.map(fields, fn f ->
        {:ok, v} =
          Ecto.Type.adapter_dump(Ecto.Adapters.Postgres, Invocation.__schema__(:type, f), row[f])

        v
      end)

    # One round trip whether the row is new or (the usual case, the lifecycle event came
    # first) already there. A conflict with a row committed after this statement's snapshot
    # was taken returns nothing; the read below covers that race.
    sql = """
    WITH ins AS (
      INSERT INTO "invocations" (#{cols}) VALUES (#{placeholders})
      ON CONFLICT ("id") DO NOTHING RETURNING #{cols}
    )
    SELECT #{cols} FROM ins
    UNION ALL
    SELECT #{cols} FROM "invocations" WHERE "id" = $1 AND NOT EXISTS (SELECT 1 FROM ins)
    """

    inv =
      case Repo.query!(sql, params, cache_statement: "conveyor_load_or_create_invocation") do
        %{rows: [values]} -> Repo.load(Invocation, {fields, values})
        %{rows: []} -> Repo.get!(Invocation, id)
      end

    if inv.project_id == ctx.project_id, do: {:ok, inv}, else: {:error, :not_found}
  end

  # --- inputs -------------------------------------------------------------------------------

  @impl true
  def init({ctx, invocation_id, stream_id}) do
    session =
      Session.new(ctx.session || Ingest.session_config(),
        invocation_id: invocation_id,
        project_id: ctx.project_id,
        keywords: ctx.keywords,
        api_key_tags: ctx.api_key_tags,
        max_log_bytes: (ctx.limits || Conveyor.Limits.defaults()).max_log_bytes
      )

    worker = %{
      ctx: ctx,
      invocation_id: invocation_id,
      stream_id: stream_id,
      session: session,
      # name => timer reference
      timers: %{},
      # {pid, monitor} of the writer shard holding this worker's batches
      writer: nil,
      # what the callback returns once the effects are carried out
      next: :noreply
    }

    {:ok, worker, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, w), do: w |> run(Session.loaded(w.session, load(w))) |> finish()

  # `acker` receives `{:ack, seq}` once the event is committed (or `{:ack_failed, seq, reason}`).
  # The call itself returns as soon as the event is absorbed, so the gRPC handler keeps
  # reading; when too much is unacknowledged the reply is deferred until the next commit,
  # which is the backpressure that eventually slows Bazel down through HTTP/2 flow control.
  @impl true
  def handle_call({:push, %V1.OrderedBuildEvent{} = obe, acker}, from, w),
    do: w |> run(Session.push(w.session, obe, acker, from)) |> finish()

  def handle_call({:lifecycle, kind, _obe}, from, w),
    do: w |> run(Session.lifecycle(w.session, kind, from)) |> finish()

  def handle_call(:summary, _from, w), do: {:reply, Session.summary(w.session), w}

  @impl true
  def handle_info({:batch_committed, ref}, w),
    do: w |> run(Session.committed(w.session, ref)) |> finish()

  def handle_info({:batch_failed, ref, reason}, w),
    do: w |> run(Session.failed(w.session, ref, reason)) |> finish()

  # The writer went away (crash, restart, shutdown). Whatever it held is lost to this
  # worker and the outcome of a batch it was committing is unknown: it may be in the row.
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{writer: {pid, ref}} = w),
    do: %{w | writer: nil} |> run(Session.writer_down(w.session)) |> finish()

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, w), do: {:noreply, w}

  def handle_info({:timeout, ref, {:session, name}}, w) do
    case Map.pop(w.timers, name) do
      {^ref, timers} -> %{w | timers: timers} |> run(Session.timer(w.session, name)) |> finish()
      # Replaced or cancelled after it fired.
      _ -> {:noreply, w}
    end
  end

  # --- effects ------------------------------------------------------------------------------

  defp run(w, {session, effects}), do: Enum.reduce(effects, %{w | session: session}, &effect/2)

  defp finish(%{next: :noreply} = w), do: {:noreply, w}
  defp finish(%{next: :hibernate} = w), do: {:noreply, %{w | next: :noreply}, :hibernate}
  defp finish(%{next: {:stop, reason}} = w), do: {:stop, reason, w}

  defp effect({:reply, from, reply}, w) do
    GenServer.reply(from, reply)
    w
  end

  defp effect({:ack, acker, seq}, w) do
    send(acker, {:ack, seq})
    w
  end

  defp effect({:nack, acker, seq, reason}, w) do
    send(acker, {:ack_failed, seq, reason})
    w
  end

  # The writer answers every batch it holds before it returns to its loop, so the only way
  # to lose an outcome is the writer process going away, which the monitor reports.
  defp effect({:submit, batch}, w) do
    case Writer.submit(WriterPool.for_invocation(w.invocation_id), batch) do
      {:ok, pid} -> watch_writer(w, pid)
      {:error, :writer_down} -> run(w, Session.failed(w.session, batch.ref, :writer_down))
    end
  end

  defp effect({:arm, name, ms}, w) do
    w = cancel(w, name)
    %{w | timers: Map.put(w.timers, name, :erlang.start_timer(ms, self(), {:session, name}))}
  end

  defp effect({:cancel, name}, w), do: cancel(w, name)

  defp effect(:reload, w) do
    w = Enum.reduce(Map.keys(w.timers), w, &cancel(&2, &1))
    run(w, Session.loaded(w.session, load(w)))
  end

  defp effect(:unregister, w) do
    Registry.unregister(w.ctx.registry, {w.ctx.project_id, w.invocation_id})
    w
  end

  defp effect({:broadcast, topic, message}, w) do
    Watch.broadcast(topic, message)
    w
  end

  defp effect({:telemetry, event, measurements, metadata}, w) do
    :telemetry.execute(event, measurements, metadata)
    w
  end

  defp effect({:log, level, message}, w) do
    Logger.log(level, message)
    w
  end

  defp effect({:finalized, inv}, w) do
    Conveyor.Artifacts.on_finalized(struct(Invocation, inv))
    w
  end

  defp effect(:hibernate, %{next: :noreply} = w), do: %{w | next: :hibernate}
  defp effect(:hibernate, w), do: w
  defp effect({:stop, reason}, w), do: %{w | next: {:stop, reason}}

  defp cancel(w, name) do
    case Map.pop(w.timers, name) do
      {nil, _} ->
        w

      {ref, timers} ->
        :erlang.cancel_timer(ref)
        %{w | timers: timers}
    end
  end

  defp watch_writer(%{writer: {pid, _ref}} = w, pid), do: w

  defp watch_writer(w, pid) do
    with {_old, ref} <- w.writer, do: Process.demonitor(ref, [:flush])
    %{w | writer: {pid, Process.monitor(pid)}}
  end

  defp load(w) do
    Retry.with_backoff(fn -> load_or_create(w.ctx, w.invocation_id, w.stream_id) end,
      label: "worker load #{w.invocation_id}"
    )
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
