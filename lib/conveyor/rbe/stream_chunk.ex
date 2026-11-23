defmodule Conveyor.Rbe.StreamChunk do
  @moduledoc """
  A chunk of the compact per-action records of one build (`Conveyor.Rbe.StreamActions`):
  the records of the successful `ActionExecuted` events one ingest batch acknowledged,
  written in that batch's fenced transaction (`Conveyor.Ingest.Writer.Transaction`), so a
  chunk exists exactly when its sequence numbers were committed, once. `first_seq` is the
  first sequence number of the batch.
  """
  use Ecto.Schema

  @primary_key false
  schema "stream_actions" do
    field :invocation_id, :binary_id, primary_key: true
    field :first_seq, :integer, primary_key: true
    field :day, :date
    field :n, :integer
    field :records, :binary
  end
end
