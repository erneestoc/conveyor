defmodule Conveyor.Invocations.Action do
  @moduledoc "An executed action reported through `ActionExecuted` (failed ones by default)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "actions" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id
    field :seq, :integer
    field :label, :string
    field :configuration_id, :string
    field :mnemonic, :string
    field :success, :boolean, default: false
    field :exit_code, :integer
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :primary_output, :string
    field :stdout_uri, :string
    field :stderr_uri, :string
    field :command_line, {:array, :string}, default: []
    field :failure_message, :string
  end
end
