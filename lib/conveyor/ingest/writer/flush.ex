defmodule Conveyor.Ingest.Writer.Flush do
  @moduledoc """
  When a writer shard commits what it has collected. Pure: the shard describes what waits
  and gets `:flush` (commit now) or `{:wait, ms}` (commit when that has passed, unless a
  later batch says otherwise).

  | What waits | Decision | Why |
  |---|---|---|
  | `max_pending` batches or more | `:flush` | a group has a size the database likes; more only adds latency |
  | `max_bytes` or more (blob mode) | `:flush` | flat-out load fills objects instead of waiting out a long hold |
  | the batch just taken ends a stream | `:flush` | Bazel is waiting on that acknowledgement to finish the build |
  | anything else | `{:wait, hold − age of the oldest batch}` | group commit: one transaction (and in blob mode one object) per hold |

  The hold is counted from when the oldest waiting batch was submitted, not from when the
  shard got to it: batches that queued behind a slow commit have already waited, and get
  `{:wait, 0}`. That is still a wait, not a flush: the shard's timer message lands behind
  whatever else queued meanwhile, so the next group takes all of it.
  """

  alias Conveyor.Ingest.Writer.Config

  @type waiting :: %{
          required(:count) => pos_integer(),
          required(:bytes) => non_neg_integer(),
          required(:oldest_ms) => integer(),
          required(:finalize?) => boolean()
        }

  @spec decide(waiting(), Config.t()) :: :flush | {:wait, non_neg_integer()}
  def decide(%{count: count}, %Config{max_pending: max}) when count >= max, do: :flush

  def decide(%{bytes: bytes}, %Config{max_bytes: max}) when is_integer(max) and bytes >= max,
    do: :flush

  def decide(%{finalize?: true}, %Config{}), do: :flush

  def decide(%{oldest_ms: age}, %Config{hold_ms: hold}),
    do: {:wait, hold |> Kernel.-(max(age, 0)) |> max(0)}
end
