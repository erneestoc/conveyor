defmodule Conveyor.Invocations.Metrics do
  @moduledoc "Full `BuildMetrics`, `BuildToolLogs` and profile summary of an invocation as JSON."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "invocation_metrics" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id, primary_key: true
    field :build_metrics, :map, default: %{}
    field :tool_logs, :map, default: %{}
    field :profile_summary, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
