defmodule Conveyor.Ingest do
  @moduledoc """
  Entry point of the ingest pipeline. The gRPC layer authenticates a stream into a
  `Context` and pushes ordered events here; a per-invocation worker orders, normalizes and
  batches them, and a group-commit writer persists them. `push/2` returns only after the
  event is durable, so the caller can acknowledge it.
  """

  alias Conveyor.Ingest.Worker
  alias Google.Devtools.Build.V1, as: V1

  defmodule Context do
    @moduledoc """
    Who is sending: the project (always decided server-side) and the API key, if any.
    `registry` and `worker_supervisor` name the ingest instance the stream lands on; tests
    start a second instance against the same database to exercise cross-node fencing.
    """
    defstruct project_id: nil,
              project_slug: nil,
              api_key_id: nil,
              api_key_tags: %{},
              keywords: [],
              instance_name: nil,
              peer: nil,
              limits: nil,
              registry: Conveyor.Ingest.Registry,
              worker_supervisor: Conveyor.Ingest.WorkerSupervisor

    @type t :: %__MODULE__{}
  end

  @type push_result :: :ok | {:error, :out_of_order | :fenced | term()}

  @doc """
  Hands one `OrderedBuildEvent` of the tool event stream to its worker. Returns once the
  event is absorbed (or later, under backpressure); `acker` receives `{:ack, seq}` when the
  event is committed and may then acknowledge it to Bazel, or `{:ack_failed, seq, reason}`.
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
        {:ack_failed, ^seq, reason} -> {:error, reason}
      after
        timeout -> {:error, :timeout}
      end
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
    case Registry.lookup(ctx.registry, stream_id.invocation_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:lifecycle, :invocation_attempt_started, obe}, :infinity)
        catch
          :exit, _ -> touch_row(ctx, stream_id)
        end

      [] ->
        touch_row(ctx, stream_id)
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
    case Registry.lookup(ctx.registry, stream_id.invocation_id) do
      [{pid, _}] ->
        try do
          case GenServer.call(pid, {:lifecycle, :invocation_attempt_finished, obe}, :infinity) do
            # Bazel sends lifecycle events and the event stream on separate connections, so
            # behind a balancer this node may hold a stray worker (started by the
            # attempt-started event) while another node owns the stream and the row. Its
            # commit is fenced; the notification itself is still valid, so record it
            # directly instead of failing the RPC, which would make Bazel abort the upload.
            {:error, {:fenced, _}} ->
              mark_lifecycle_finished(:invocation_attempt_finished, stream_id.invocation_id)

            other ->
              other
          end
        catch
          :exit, _ ->
            mark_lifecycle_finished(:invocation_attempt_finished, stream_id.invocation_id)
        end

      [] ->
        mark_lifecycle_finished(:invocation_attempt_finished, stream_id.invocation_id)
    end
  end

  # build_enqueued / build_finished carry only a build id; nothing to persist yet.
  def lifecycle(_ctx, _obe), do: :ok

  # Database errors surface as UNAVAILABLE so that Bazel retries, never as an internal error.
  defp touch_row(ctx, stream_id) do
    Worker.load_or_create!(ctx, stream_id.invocation_id, stream_id)
    :ok
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, {:unavailable, e}}
  end

  defp mark_lifecycle_finished(:invocation_attempt_finished, invocation_id) do
    import Ecto.Query, only: [from: 2]

    Conveyor.Repo.update_all(
      from(i in Conveyor.Invocations.Invocation, where: i.id == ^invocation_id),
      set: [lifecycle_finished: true]
    )

    :ok
  end

  @doc "Finds or starts the worker for an invocation."
  @spec worker(Context.t(), String.t(), V1.StreamId.t()) :: {:ok, pid()} | {:error, term()}
  def worker(ctx, invocation_id, stream_id) do
    case Registry.lookup(ctx.registry, invocation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
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
