defmodule Conveyor.Rbe.Groups do
  @moduledoc """
  Cache groups: projects that build one codebase against what should be one cache (a
  monorepo whose apps are a project each). A project names its group in
  `settings["cache_group"]`; without one its scope is itself, which is what every project
  was before groups existed.

  Membership is a statement about sharing: a member's duplicates are counted against the
  executions of every other member, and each member sees the group's totals. It is
  therefore set by a global admin, never by a project's own admin. Names of other
  projects and their targets are shown only to viewers who may see those projects
  (`Conveyor.Rbe.Report` takes the viewer's visible projects).

  A project that joins a group contributes the logs parsed from then on; what it parsed
  before stays in its own scope.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Conveyor.Projects
  alias Conveyor.Projects.Project
  alias Conveyor.Repo

  @type t :: %__MODULE__{}

  schema "cache_groups" do
    field :name, :string
    field :inserted_at, :utc_datetime_usec
  end

  @name_re ~r/^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$/

  @doc "The group's name of a project, or nil."
  @spec name(Project.t()) :: String.t() | nil
  def name(%Project{settings: settings}), do: Map.get(settings || %{}, "cache_group")

  @doc "The group a project belongs to, or nil."
  @spec of(Project.t()) :: t() | nil
  def of(%Project{} = project) do
    case name(project) do
      nil -> nil
      name -> Repo.get_by(__MODULE__, name: name)
    end
  end

  @spec get_by_name(String.t()) :: t() | nil
  def get_by_name(name), do: Repo.get_by(__MODULE__, name: name)

  @doc "Puts a project into the group of that name (created when new); blank leaves the group."
  @spec put(Project.t(), String.t() | nil) :: {:ok, Project.t()} | {:error, String.t()}
  def put(%Project{} = project, name) do
    case String.trim(name || "") do
      "" ->
        save(project, Map.delete(project.settings || %{}, "cache_group"))

      name ->
        if Regex.match?(@name_re, name) do
          Repo.insert_all(__MODULE__, [%{name: name, inserted_at: DateTime.utc_now()}],
            on_conflict: :nothing,
            conflict_target: [:name]
          )

          save(project, Map.put(project.settings || %{}, "cache_group", name))
        else
          {:error, "a cache group name is lowercase letters, digits, dots, dashes or underscores"}
        end
    end
  end

  defp save(project, settings) do
    case Projects.update_project(project, %{settings: settings}) do
      {:ok, project} -> {:ok, project}
      {:error, _changeset} -> {:error, "could not save the cache group"}
    end
  end

  @doc "The projects of a group (archived ones included: their builds still count), by id."
  @spec members(t() | nil) :: [Project.t()]
  def members(nil), do: []

  def members(%__MODULE__{name: name}) do
    Repo.all(
      from p in Project,
        where: fragment("? ->> 'cache_group' = ?", p.settings, ^name),
        order_by: p.id
    )
  end

  @doc "The scope number of a group in `action_keys`."
  @spec scope(t()) :: integer()
  def scope(%__MODULE__{id: id}), do: -id

  @doc """
  The scopes a project's executions are merged into, with the projects of each: itself,
  then its group when it has one. Always in that order, which is part of the lock order.
  """
  @spec scopes(Project.t()) :: [{integer(), [integer()]}]
  def scopes(%Project{id: id} = project) do
    case of(project) do
      nil -> [{id, [id]}]
      group -> [{id, [id]}, {scope(group), group |> members() |> Enum.map(& &1.id)}]
    end
  end

  @doc "Every scope that exists (for pruning what belongs to none)."
  @spec live_scopes() :: [integer()]
  def live_scopes do
    Repo.all(from p in Project, select: p.id) ++
      Repo.all(from g in __MODULE__, select: fragment("-?", g.id))
  end
end
