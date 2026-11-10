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
    |> validate_blob_prefix()
  end

  # Prefixes of the blob store that belong to the server: the raw log lives under `rawlog/`
  # (`Conveyor.RawLog`). A project prefix starts with a letter or digit, so anything the
  # server adds later can start with `_` without reserving a name here.
  @reserved_prefixes ~w(rawlog)

  @doc "Blob key prefixes no project may use."
  @spec reserved_prefixes() :: [String.t()]
  def reserved_prefixes, do: @reserved_prefixes

  @doc "The key prefix a project's blobs are written under: its setting, or the slug."
  @spec blob_prefix(t()) :: String.t() | nil
  def blob_prefix(%__MODULE__{slug: slug, settings: settings}),
    do: Map.get(settings || %{}, "blob_prefix") || slug

  # A project owns its prefix: `Conveyor.Blobs` deletes `<prefix>/<digest>` when the
  # project's row goes, so two projects on one prefix would delete each other's bytes, and
  # a prefix of the server's own would put a project's blobs among the raw log's objects.
  # Checked whenever the prefix a project writes under changes (a new project, a new slug,
  # a new setting); an existing project keeps what it has until then.
  defp validate_blob_prefix(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_blob_prefix(changeset) do
    prefix = blob_prefix(apply_changes(changeset))
    field = if get_field(changeset, :settings)["blob_prefix"], do: :settings, else: :slug

    cond do
      changeset.data.id != nil and prefix == blob_prefix(changeset.data) ->
        changeset

      prefix in @reserved_prefixes ->
        add_error(changeset, field, "blob prefix \"#{prefix}\" is reserved for the server")

      prefix_taken?(prefix, changeset.data.id) ->
        add_error(changeset, field, "blob prefix \"#{prefix}\" belongs to another project")

      true ->
        changeset
    end
  end

  # Taken by a project that writes under it now, or by blobs another project stored under
  # it before its prefix changed (rows record the prefix they were written under).
  defp prefix_taken?(prefix, id) do
    import Ecto.Query

    others = if id, do: dynamic([p], p.id != ^id), else: true
    other_blobs = if id, do: dynamic([b], b.project_id != ^id), else: true

    Conveyor.Repo.exists?(
      from p in __MODULE__,
        where: ^others,
        where: fragment("coalesce(?->>'blob_prefix', ?) = ?", p.settings, p.slug, ^prefix)
    ) or
      Conveyor.Repo.exists?(
        from b in "blobs", where: ^other_blobs, where: b.prefix == ^prefix, select: 1
      )
  end
end
