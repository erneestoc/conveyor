defmodule Conveyor.Ingest.WriterPool do
  @moduledoc """
  A fixed pool of group-commit writers; batches are sharded by invocation id. The shard
  count and the shards' configuration (`Writer.Config.from_env/0`) are fixed when the pool
  starts.
  """
  use Supervisor

  alias Conveyor.Ingest.Writer

  @shards {__MODULE__, :shards}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    shards =
      Application.get_env(:conveyor, Conveyor.Ingest)[:writer_shards] ||
        System.schedulers_online()

    # Read on every submit: a persistent term costs nothing to read and this one is written
    # once per boot (the same value again is not a write).
    :persistent_term.put(@shards, shards)

    config = Writer.Config.from_env()

    children =
      for i <- 0..(shards - 1),
          do: Supervisor.child_spec({Writer, shard: i, config: config}, id: {Writer, i})

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "How many shards the pool has (0 before it has ever started on this node)."
  @spec shards() :: non_neg_integer()
  def shards, do: :persistent_term.get(@shards, 0)

  @doc "The shard responsible for an invocation (what `Writer.submit/2` takes)."
  @spec for_invocation(String.t()) :: Writer.shard()
  def for_invocation(invocation_id), do: :erlang.phash2(invocation_id, max(shards(), 1))

  @doc """
  The pool's commit pressure, for whoever decides whether to take more work: the batches
  and bytes handed to the shards and not answered yet, and `oldest_ms`, the age of the
  oldest unanswered batch on any shard. A healthy node reads a few hundred milliseconds at
  most (the writer's hold plus a commit); an age that keeps growing means commits are not
  keeping up, and at `writer_deadline_ms` batches start to expire. A read of a few
  counters per shard: cheap enough to call per request.
  """
  @spec pressure() :: %{
          batches: non_neg_integer(),
          bytes: non_neg_integer(),
          oldest_ms: non_neg_integer()
        }
  def pressure do
    Enum.reduce(0..(shards() - 1)//1, %{batches: 0, bytes: 0, oldest_ms: 0}, fn shard, acc ->
      p = Writer.pressure(shard)

      %{
        batches: acc.batches + p.batches,
        bytes: acc.bytes + p.bytes,
        oldest_ms: max(acc.oldest_ms, p.oldest_ms)
      }
    end)
  end
end
