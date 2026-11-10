defmodule Conveyor.Ingest do
  @moduledoc """
  Entry point of the ingest pipeline. The gRPC layer authenticates a stream into a
  `Context` and pushes ordered events here; a per-invocation worker runs the stream's
  session (`Conveyor.Ingest.Session`: order, dedup, batches, back-pressure), and a
  group-commit writer persists the batches. `push/3` returns once the event is accepted;
  the acknowledgement follows the commit as a message to the acker.

  An invocation id belongs to the project that created it: for a context of another
  project every function here answers as if the build did not exist (`{:error, :not_found}`,
  or `:ok` without effect for the finish notification) and writes nothing.
  """

  alias Conveyor.Admission
  alias Conveyor.Ingest.Worker
  alias Google.Devtools.Build.V1, as: V1

  defmodule Context do
    @moduledoc """
    Who is sending: the project (always decided server-side) and the API key, if any.
    `registry` and `worker_supervisor` name the ingest instance the stream lands on; tests
    start a second instance against the same database to exercise cross-node fencing.
    `session` overrides the node's session configuration (`Conveyor.Ingest.session_config/0`)
    for the worker this context starts.
    """
    defstruct project_id: nil,
              project_slug: nil,
              api_key_id: nil,
              api_key_tags: %{},
              keywords: [],
              instance_name: nil,
              peer: nil,
              limits: nil,
              session: nil,
              registry: Conveyor.Ingest.Registry,
              worker_supervisor: Conveyor.Ingest.WorkerSupervisor

    @type t :: %__MODULE__{}
  end

  @type push_result :: :ok | {:error, :out_of_order | :not_found | {:fenced, integer()} | term()}

  @doc """
  Hands one `OrderedBuildEvent` of the tool event stream to its worker. Returns once the
  event is absorbed (or later, under backpressure); `acker` receives `{:ack, seq}` when the
  event is committed and may then acknowledge it to Bazel (`{:ack, seq, :resent}` for a
  resend of an event committed earlier), or `{:ack_failed, seq, reason}`.
  """
  @spec push(Context.t(), V1.OrderedBuildEvent.t(), pid()) :: push_result()
  def push(
        %Context{} = ctx,
        %V1.OrderedBuildEvent{stream_id: %V1.StreamId{invocation_id: id}} = obe,
        acker
      )
      when id != "" do
    with {:ok, pid} <- worker(ctx, id, obe.stream_id) do
      try do
        GenServer.call(pid, {:push, obe, acker}, :infinity)
      catch
        :exit, {reason, _} -> {:error, {:worker_down, reason}}
      end
    end
  end

  def push(_ctx, _obe, _acker), do: {:error, :missing_invocation_id}

  @doc "Convenience for tests: pushes and waits for the ack."
  @spec push_sync(Context.t(), V1.OrderedBuildEvent.t(), timeout()) :: push_result()
  def push_sync(ctx, obe, timeout \\ 5_000) do
    with :ok <- push(ctx, obe, self()) do
      seq = obe.sequence_number

      receive do
        {:ack, ^seq} -> :ok
        {:ack, ^seq, :resent} -> :ok
        {:ack_failed, ^seq, reason} -> {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  Pushes a whole stream the way the gRPC handler does, events first and acknowledgements
  read as they come, and returns once the last one is committed: a file of a thousand
  events costs a few commits rather than a thousand batch holds. The calling process
  receives the acknowledgements. `timeout` bounds the wait for each next acknowledgement.
  On an error nothing after the reported sequence was accepted; what committed before it
  stays (a retry resumes through dedup). The stream passes admission like any other:
  `{:error, {seq, {:refused, reason}}}` when a door refuses it (`seq` 0: before any event).
  """
  @spec push_all(Context.t(), Enumerable.t(V1.OrderedBuildEvent.t()), timeout()) ::
          :ok | {:error, {seq :: non_neg_integer(), reason :: term()}}
  def push_all(%Context{} = ctx, events, timeout \\ 30_000) do
    # The same doors as a gRPC stream: a slot of the key, the build's class at the first
    # event, every event.
    case Admission.open_stream(ctx.api_key_id, ctx.limits) do
      {:ok, ticket} ->
        try do
          push_stream(ctx, events, ticket, timeout)
        after
          Admission.close_stream(ticket)
        end

      {:refuse, reason} ->
        {:error, {0, {:refused, reason}}}
    end
  end

  defp push_stream(ctx, events, ticket, timeout) do
    pushed =
      Enum.reduce_while(events, {:ok, 0}, fn obe, {:ok, last} ->
        with :ok <- if(last == 0, do: Admission.build(ticket, resumed?(ctx, obe)), else: :ok),
             :ok <- Admission.event(ticket),
             :ok <- push(ctx, obe, self()) do
          {:cont, {:ok, obe.sequence_number}}
        else
          {:refuse, reason} -> {:halt, {:error, {obe.sequence_number, {:refused, reason}}}}
          {:error, reason} -> {:halt, {:error, {obe.sequence_number, reason}}}
        end
      end)

    case pushed do
      {:ok, 0} -> :ok
      {:ok, last} -> await_acks(last, timeout)
      {:error, _} = error -> error
    end
  end

  @doc """
  Whether the first event of a stream belongs to a build in progress: it does not start at
  sequence 1 (Bazel resends from its last acknowledgement, so earlier events committed
  somewhere), or its session lives on this node. No database read. A retry of a build of
  which nothing was acknowledged yet looks new, and is treated as new.
  """
  @spec resumed?(Context.t(), V1.OrderedBuildEvent.t()) :: boolean()
  def resumed?(%Context{} = ctx, %V1.OrderedBuildEvent{sequence_number: seq, stream_id: stream_id}) do
    seq > 1 or
      (stream_id != nil and
         Worker.whereis(ctx.registry, ctx.project_id, stream_id.invocation_id) != nil)
  end

  # Acks arrive in sequence order; the last one means every event before it committed.
  defp await_acks(last, timeout) do
    receive do
      {:ack, ^last} -> :ok
      {:ack, ^last, :resent} -> :ok
      {:ack, _seq} -> await_acks(last, timeout)
      {:ack, _seq, :resent} -> await_acks(last, timeout)
      {:ack_failed, seq, reason} -> {:error, {seq, reason}}
    after
      timeout -> {:error, {last, :timeout}}
    end
  end

  @doc "Handles a lifecycle event (`PublishLifecycleEvent`)."
  @spec lifecycle(Context.t(), V1.OrderedBuildEvent.t()) :: :ok | {:error, term()}
  # The attempt-started notification makes the build visible before its first event. It
  # creates the row directly and never starts a worker: Bazel sends lifecycle events and
  # the event stream on separate connections, so behind a balancer this node is often not
  # the one that will own the stream, and a worker started here would only fence the real
  # one (the trial left builds `in_progress` that way). A live worker is told, so a build
  # whose stream already started here stays in one place.
  def lifecycle(
        %Context{} = ctx,
        %V1.OrderedBuildEvent{
          stream_id: stream_id,
          event: %V1.BuildEvent{event: {:invocation_attempt_started, _}}
        } = obe
      )
      when stream_id.invocation_id != "" do
    case Worker.whereis(ctx.registry, ctx.project_id, stream_id.invocation_id) do
      nil ->
        # The notification that announces a build is the stream door for it: a node that
        # is shedding refuses the build here, before its row exists.
        case Admission.build(ctx.api_key_id, false) do
          :ok -> touch_row(ctx, stream_id)
          {:refuse, reason} -> {:error, {:refused, reason}}
        end

      pid ->
        try do
          GenServer.call(pid, {:lifecycle, :invocation_attempt_started, obe}, :infinity)
        catch
          :exit, _ -> touch_row(ctx, stream_id)
        end
    end
  end

  # The finish notification usually arrives after the worker has finalized and exited; it
  # must not resurrect a worker for a finished build, so only a live worker is called and
  # the row is updated directly otherwise.
  def lifecycle(
        %Context{} = ctx,
        %V1.OrderedBuildEvent{
          stream_id: stream_id,
          event: %V1.BuildEvent{event: {:invocation_attempt_finished, _}}
        } = obe
      )
      when stream_id.invocation_id != "" do
    case Worker.whereis(ctx.registry, ctx.project_id, stream_id.invocation_id) do
      nil ->
        mark_lifecycle_finished(ctx, stream_id.invocation_id)

      pid ->
        try do
          case GenServer.call(pid, {:lifecycle, :invocation_attempt_finished, obe}, :infinity) do
            # Bazel sends lifecycle events and the event stream on separate connections, so
            # behind a balancer this node may hold a stray worker (started by the
            # attempt-started event) while another node owns the stream and the row. Its
            # commit is fenced; the notification itself is still valid, so record it
            # directly instead of failing the RPC, which would make Bazel abort the upload.
            {:error, {:fenced, _}} ->
              mark_lifecycle_finished(ctx, stream_id.invocation_id)

            other ->
              other
          end
        catch
          :exit, _ -> mark_lifecycle_finished(ctx, stream_id.invocation_id)
        end
    end
  end

  # build_enqueued / build_finished carry only a build id; nothing to persist yet.
  def lifecycle(_ctx, _obe), do: :ok

  # Database errors surface as UNAVAILABLE so that Bazel retries, never as an internal error.
  defp touch_row(ctx, stream_id) do
    with {:ok, _inv} <- Worker.load_or_create(ctx, stream_id.invocation_id, stream_id), do: :ok
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:unavailable, e}}
  end

  # Scoped by project: for an id of another project this updates nothing and answers as it
  # does for an id that does not exist, so the notification reveals nothing. Database
  # errors surface as UNAVAILABLE here too.
  defp mark_lifecycle_finished(%Context{project_id: project_id}, invocation_id) do
    import Ecto.Query, only: [from: 2]

    Conveyor.Repo.update_all(
      from(i in Conveyor.Invocations.Invocation,
        where: i.id == ^invocation_id and i.project_id == ^project_id
      ),
      set: [lifecycle_finished: true]
    )

    :ok
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:unavailable, e}}
  end

  @doc "Finds or starts the worker for an invocation."
  @spec worker(Context.t(), String.t(), V1.StreamId.t()) :: {:ok, pid()} | {:error, term()}
  def worker(ctx, invocation_id, stream_id) do
    case Worker.whereis(ctx.registry, ctx.project_id, invocation_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               ctx.worker_supervisor,
               {Worker, {ctx, invocation_id, stream_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  The node's stream session configuration, read from the application environment once per
  session start (`config :conveyor, Conveyor.Ingest`).
  """
  @spec session_config() :: Conveyor.Ingest.Session.Config.t()
  def session_config do
    env = Application.get_env(:conveyor, __MODULE__, [])
    defaults = %Conveyor.Ingest.Session.Config{}

    overrides =
      for {key, default} <- Map.from_struct(defaults), do: {key, Keyword.get(env, key, default)}

    struct(defaults, overrides)
  end

  @doc """
  The idle window of a stream session. A live session changes its row with every commit and
  marks its build disconnected itself after one window without events, so a row unchanged
  for two windows has no session anywhere: the rule the stale sweep, build retention and
  the raw archive rely on (`docs/spec/Retention.tla`).
  """
  @spec idle_timeout_ms() :: non_neg_integer()
  def idle_timeout_ms, do: session_config().idle_timeout_ms

  @doc "Configuration value of the ingest pipeline."
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil) do
    Application.get_env(:conveyor, __MODULE__, []) |> Keyword.get(key, default)
  end

  @doc "PubSub topic carrying list-level updates for a project."
  def project_topic(project_id), do: "project:#{project_id}:invocations"
  @doc "PubSub topic carrying list-level updates for every project."
  def all_topic, do: "invocations:all"
  @doc "PubSub topic carrying detail updates of one invocation."
  def invocation_topic(id), do: "invocation:#{id}"
  @doc "PubSub topic carrying log chunks of one invocation."
  def log_topic(id), do: "invocation:#{id}:log"
end
