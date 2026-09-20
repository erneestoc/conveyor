defmodule Conveyor.Ingest.Supervisor do
  @moduledoc """
  Supervises the ingest registry, the tag counter, the writer pool and the per-invocation
  workers. With `:registry` and `:worker_supervisor` names given, starts a second, bare
  instance (registry + workers only, sharing the writers) — used by tests to act as
  another node against the same database.
  """
  use Supervisor

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Conveyor.Ingest.Registry)
    workers = Keyword.get(opts, :worker_supervisor, Conveyor.Ingest.WorkerSupervisor)

    shared =
      if registry == Conveyor.Ingest.Registry,
        do: [Conveyor.Ingest.TagCounter, Conveyor.Ingest.WriterPool],
        else: []

    children =
      [{Registry, keys: :unique, name: registry}] ++
        shared ++
        [
          {DynamicSupervisor,
           name: workers, strategy: :one_for_one, max_restarts: 1000, max_seconds: 5}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
