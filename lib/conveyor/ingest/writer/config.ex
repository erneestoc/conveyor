defmodule Conveyor.Ingest.Writer.Config do
  @moduledoc """
  The knobs of a writer shard, fixed when the shard starts. `from_env/0` builds the node's
  from the application environment (the pool does, once, for all its shards); a test
  starts a shard with its own.
  """

  alias Conveyor.RawLog

  defstruct hold_ms: 20,
            max_pending: 256,
            max_bytes: nil,
            blob?: false,
            deadline_ms: 20_000,
            retry_delays: [50, 200, 800]

  @type t :: %__MODULE__{
          # how long a shard collects batches before it commits them
          hold_ms: non_neg_integer(),
          # a shard commits at once when this many batches wait
          max_pending: pos_integer(),
          # ... or this many bytes of batches (blob mode; nil: no limit)
          max_bytes: pos_integer() | nil,
          # the group's raw bytes go into one raw-log object instead of the segment rows
          blob?: boolean(),
          # how long after its submission a batch may still start a commit
          deadline_ms: non_neg_integer(),
          # waits between a group's attempts while the database or the store is unavailable
          retry_delays: [non_neg_integer()]
        }

  @doc """
  The node's configuration: `config :conveyor, Conveyor.Ingest` (`writer_flush_ms`,
  `writer_max_pending`, `writer_deadline_ms`, `writer_retry_delays`) and, in blob mode,
  `config :conveyor, Conveyor.RawLog` (the hold and the byte limit are the raw log's:
  one object per shard per hold).
  """
  @spec from_env() :: t()
  def from_env do
    ingest = Application.get_env(:conveyor, Conveyor.Ingest, [])
    defaults = %__MODULE__{}
    blob? = RawLog.blob_mode?()

    %__MODULE__{
      hold_ms:
        if(blob?,
          do: RawLog.flush_ms(),
          else: Keyword.get(ingest, :writer_flush_ms, defaults.hold_ms)
        ),
      max_pending: Keyword.get(ingest, :writer_max_pending, defaults.max_pending),
      max_bytes: if(blob?, do: RawLog.flush_bytes()),
      blob?: blob?,
      deadline_ms: Keyword.get(ingest, :writer_deadline_ms, defaults.deadline_ms),
      retry_delays: Keyword.get(ingest, :writer_retry_delays, defaults.retry_delays)
    }
  end
end
