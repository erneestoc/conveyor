defmodule Conveyor.IngestCase do
  @moduledoc """
  Database sandbox in shared mode (workers and writers are separate processes) plus the
  gRPC endpoint on a free port. Tests using it must be `async: false`.
  """
  use ExUnit.CaseTemplate

  alias Conveyor.Ingest.Context

  using do
    quote do
      import Conveyor.GrpcCase, only: [fixture: 1]
      import Conveyor.IngestCase
      alias Conveyor.Repo
    end
  end

  setup_all do
    port = Conveyor.GrpcCase.free_port()

    pid =
      start_supervised!(
        {GRPC.Server.Supervisor, Conveyor.Grpc.Endpoint.server_opts(port)},
        id: {:grpc_server, port}
      )

    on_exit(fn -> Process.alive?(pid) && Supervisor.stop(pid) end)
    {:ok, grpc_port: port}
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Conveyor.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Conveyor.Projects.ApiKeyCache.clear()
    project = Conveyor.Projects.ensure_default_project!()
    {:ok, project: project, ctx: %Context{project_id: project.id, project_slug: project.slug}}
  end

  @doc "Waits until the worker for an invocation has exited (finalization + linger)."
  def await_worker_exit(invocation_id, timeout \\ 5_000) do
    case worker_pid(invocation_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          timeout -> {:error, :still_running}
        end
    end
  end

  @doc "The live worker of an invocation (whatever its project) in an ingest instance, or nil."
  def worker_pid(registry \\ Conveyor.Ingest.Registry, invocation_id) do
    case Registry.select(registry, [{{{:_, invocation_id}, :"$1", :_}, [], [:"$1"]}]) do
      [pid] -> pid
      [] -> nil
    end
  end

  @doc """
  Switches the raw log's mode for the rest of the test. Writer shards read their
  configuration when they start, so the pool is restarted with it, and again with the
  previous configuration when the test ends.
  """
  def raw_log_mode!(mode, opts \\ []) do
    previous = Application.get_env(:conveyor, Conveyor.RawLog)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:conveyor, Conveyor.RawLog, previous)
      restart_writers()
    end)

    Application.put_env(:conveyor, Conveyor.RawLog, [mode: mode] ++ opts)
    restart_writers()
  end

  defp restart_writers do
    :ok = Supervisor.terminate_child(Conveyor.Ingest.Supervisor, Conveyor.Ingest.WriterPool)
    {:ok, _} = Supervisor.restart_child(Conveyor.Ingest.Supervisor, Conveyor.Ingest.WriterPool)
    :ok
  end

  @doc "Reloads an invocation from the database."
  def reload(invocation_id),
    do: Conveyor.Repo.get!(Conveyor.Invocations.Invocation, invocation_id)
end
