defmodule Conveyor.Projects.Segment do
  @moduledoc "A saved dashboard query with a name, ordered per project."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "segments" do
    field :name, :string
    field :query, :string, default: ""
    field :position, :integer, default: 0
    belongs_to :project, Conveyor.Projects.Project
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [:name, :query, :position])
    |> update_change(:name, &String.trim/1)
    |> update_change(:query, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 40)
    |> validate_format(:name, ~r/^[^,]+$/, message: "cannot contain commas")
    |> validate_query()
    |> unique_constraint([:project_id, :name],
      error_key: :name,
      message: "is already a segment of this project"
    )
  end

  defp validate_query(changeset) do
    validate_change(changeset, :query, fn :query, query ->
      case Conveyor.Query.parse(query) do
        {:ok, _} -> []
        {:error, message} -> [query: message]
      end
    end)
  end
end
