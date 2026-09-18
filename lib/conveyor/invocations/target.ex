defmodule Conveyor.Invocations.Target do
  @moduledoc "A configured target of an invocation and its build/test outcome."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "targets" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id
    field :label, :string
    field :configuration_id, :string, default: ""
    field :aspect, :string, default: ""
    field :kind, :string
    field :test_size, :string
    field :status, :string, default: "configured"
    field :test_status, :string
    field :failure_message, :string
    field :output_groups, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
  end
end
