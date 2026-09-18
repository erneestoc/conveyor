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
    @moduledoc "Who is sending: the project (always decided server-side) and the API key, if any."
    defstruct project_id: nil,
              project_slug: nil,
              api_key_id: nil,
              api_key_tags: %{},
              keywords: [],
              instance_name: nil,
              peer: nil

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
  def lifecycle(
        %Context{} = ctx,
        %V1.OrderedBuildEvent{
          stream_id: stream_id,
          event: %V1.BuildEvent{event: {:invocation_attempt_started, _}}
        } = obe
      )
      when stream_id.invocation_id != "" do
    with {:ok, pid} <- worker(ctx, stream_id.invocation_id, stream_id) do
      try do
        GenServer.call(pid, {:lifecycle, :invocation_attempt_started, obe}, :infinity)
      catch
        # A worker that died while loading (e.g. database unavailable) must surface as
        # UNAVAILABLE so that Bazel retries, never as an internal error.
        :exit, {reason, _} -> {:error, {:worker_down, reason}}
      end
    end
  end

  # The finish notification usually arrives after the worker has finalized and exited; it
  # must not resurrect a worker for a finished build, so only a live worker is called and
  # the row is updated directly otherwise.
  def lifecycle(
        %Context{},
        %V1.OrderedBuildEvent{
          stream_id: stream_id,
          event: %V1.BuildEvent{event: {:invocation_attempt_finished, _}}
        } = obe
      )
      when stream_id.invocation_id != "" do
    case Registry.lookup(Conveyor.Ingest.Registry, stream_id.invocation_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:lifecycle, :invocation_attempt_finished, obe}, :infinity)
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
    case Registry.lookup(Conveyor.Ingest.Registry, invocation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Conveyor.Ingest.WorkerSupervisor,
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
