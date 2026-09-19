defmodule Conveyor.Invocations.Artifact do
  @moduledoc "A named file attached to an invocation, backed by a blob."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "invocation_artifacts" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id
    field :name, :string
    field :digest, :string
    field :size, :integer
    field :content_type, :string
    field :source, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
