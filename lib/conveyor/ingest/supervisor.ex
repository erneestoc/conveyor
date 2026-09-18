defmodule Conveyor.Ingest.Supervisor do
  @moduledoc "Supervises the ingest registry, the writer pool and the per-invocation workers."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Conveyor.Ingest.Registry},
      Conveyor.Ingest.WriterPool,
      {DynamicSupervisor,
       name: Conveyor.Ingest.WorkerSupervisor,
       strategy: :one_for_one,
       max_restarts: 1000,
       max_seconds: 5}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
