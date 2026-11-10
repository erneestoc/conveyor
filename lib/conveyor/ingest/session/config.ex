defmodule Conveyor.Ingest.Session.Config do
  @moduledoc """
  The knobs of a stream session, fixed when the session starts. `Conveyor.Ingest.session_config/0`
  builds the node's from the application environment; a `Conveyor.Ingest.Context` may carry
  its own (tests do, instead of changing the environment).
  """

  defstruct max_unacked_events: 2_000,
            batch_max_events: 500,
            batch_max_bytes: 256 * 1024,
            batch_flush_ms: 50,
            idle_timeout_ms: 600_000,
            linger_ms: 30_000,
            broadcast_interval_ms: 250,
            refusal_ms: 1_000

  @type t :: %__MODULE__{
          max_unacked_events: pos_integer(),
          batch_max_events: pos_integer(),
          batch_max_bytes: pos_integer(),
          batch_flush_ms: non_neg_integer(),
          idle_timeout_ms: non_neg_integer(),
          linger_ms: non_neg_integer(),
          broadcast_interval_ms: non_neg_integer(),
          refusal_ms: non_neg_integer()
        }
end
