defmodule Conveyor.Ingest.WriterPool do
  @moduledoc "A fixed pool of group-commit writers; batches are sharded by invocation id."
  use Supervisor

  alias Conveyor.Ingest.Writer

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      for i <- 0..(shards() - 1), do: Supervisor.child_spec({Writer, shard: i}, id: {Writer, i})

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec shards() :: pos_integer()
  def shards,
    do:
      Application.get_env(:conveyor, Conveyor.Ingest)[:writer_shards] ||
        System.schedulers_online()

  @doc "The writer responsible for an invocation."
  @spec for_invocation(String.t()) :: GenServer.name()
  def for_invocation(invocation_id), do: Writer.name(:erlang.phash2(invocation_id, shards()))
end
