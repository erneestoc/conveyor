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
        {GRPC.Server.Supervisor,
         endpoint: Conveyor.Grpc.Endpoint, port: port, start_server: true},
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
    case Registry.lookup(Conveyor.Ingest.Registry, invocation_id) do
      [] ->
        :ok

      [{pid, _}] ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          timeout -> {:error, :still_running}
        end
    end
  end

  @doc "Reloads an invocation from the database."
  def reload(invocation_id),
    do: Conveyor.Repo.get!(Conveyor.Invocations.Invocation, invocation_id)
end
