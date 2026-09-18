defmodule Conveyor.Invocations.TestResult do
  @moduledoc "One test attempt: a (label, configuration, run, shard, attempt) tuple."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "test_results" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id
    field :label, :string
    field :configuration_id, :string, default: ""
    field :run, :integer, default: 1
    field :shard, :integer, default: 1
    field :attempt, :integer, default: 1
    field :status, :string
    field :cached_locally, :boolean, default: false
    field :cached_remotely, :boolean, default: false
    field :strategy, :string
    field :hostname, :string
    field :started_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :exit_code, :integer
    field :files, :map, default: %{}
    field :warnings, {:array, :string}, default: []
  end
end
