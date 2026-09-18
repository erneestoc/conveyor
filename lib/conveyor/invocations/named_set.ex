defmodule Conveyor.Invocations.NamedSet do
  @moduledoc "A `NamedSetOfFiles` node: files plus references to child sets."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "named_sets" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id
    field :set_id, :string
    field :files, :map, default: %{}
    field :child_set_ids, {:array, :string}, default: []
  end
end
