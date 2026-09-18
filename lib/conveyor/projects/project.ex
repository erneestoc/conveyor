defmodule Conveyor.Projects.Project do
  @moduledoc "A project (an app, repository or team). Every invocation and API key belongs to one."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "projects" do
    field :slug, :string
    field :name, :string
    field :settings, :map, default: %{}
    field :archived_at, :utc_datetime_usec
    has_many :api_keys, Conveyor.Projects.ApiKey
    timestamps(type: :utc_datetime_usec)
  end

  @slug_re ~r/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:slug, :name, :settings])
    |> update_change(:slug, &String.downcase/1)
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @slug_re, message: "must be lowercase letters, digits and dashes")
    |> validate_length(:name, min: 1, max: 120)
    |> unique_constraint(:slug)
  end
end
