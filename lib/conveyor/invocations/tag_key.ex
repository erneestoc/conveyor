defmodule Conveyor.Invocations.TagKey do
  @moduledoc "Observed tag key/value pairs per project, for facets and autocomplete."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "tag_keys" do
    belongs_to :project, Conveyor.Projects.Project
    field :key, :string
    field :value, :string
    field :count, :integer, default: 0
    field :last_seen_at, :utc_datetime_usec
  end
end
