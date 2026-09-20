defmodule Conveyor.Projects.Segments do
  @moduledoc """
  Segments are named saved queries used to split dashboards (Local vs CI, human vs AI…),
  stored per project in `segments` and ordered by `position`. Projects without their own
  segments (and the all-projects dashboard) use the defaults.
  """
  import Ecto.Query

  alias Conveyor.Projects.{Project, Segment}
  alias Conveyor.Repo

  @defaults [%{"name" => "Local", "query" => "ci!=true"}, %{"name" => "CI", "query" => "ci:true"}]

  @spec defaults() :: [map()]
  def defaults, do: @defaults

  @doc "The segments a dashboard splits by: the project's own, or the defaults."
  @spec for_project(Project.t() | nil) :: [map()]
  def for_project(%Project{id: id}) do
    case list(id) do
      [] -> @defaults
      segments -> Enum.map(segments, &%{"name" => &1.name, "query" => &1.query})
    end
  end

  def for_project(_), do: @defaults

  @spec list(integer()) :: [Segment.t()]
  def list(project_id) do
    Segment
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], asc: s.position, asc: s.id)
    |> Repo.all()
  end

  @spec get!(integer() | String.t()) :: Segment.t()
  def get!(id), do: Repo.get!(Segment, id)

  @spec create(Project.t(), map()) :: {:ok, Segment.t()} | {:error, Ecto.Changeset.t()}
  def create(%Project{id: project_id}, attrs) do
    next =
      Segment
      |> where([s], s.project_id == ^project_id)
      |> select([s], max(s.position))
      |> Repo.one()

    %Segment{project_id: project_id, position: (next || 0) + 1}
    |> Segment.changeset(attrs)
    |> Repo.insert()
  end

  @spec delete(Segment.t()) :: {:ok, Segment.t()}
  def delete(%Segment{} = segment), do: Repo.delete(segment)

  @doc "Swaps the segment with its neighbour above (`:up`) or below (`:down`)."
  @spec move(Segment.t(), :up | :down) :: :ok
  def move(%Segment{} = segment, direction) do
    siblings = list(segment.project_id)
    index = Enum.find_index(siblings, &(&1.id == segment.id))
    other = if direction == :up, do: index - 1, else: index + 1

    if other >= 0 and other < length(siblings) do
      # Positions are renumbered from the swapped order, so ties and gaps cannot accumulate.
      siblings
      |> List.update_at(index, fn _ -> Enum.at(siblings, other) end)
      |> List.update_at(other, fn _ -> Enum.at(siblings, index) end)
      |> Enum.with_index(1)
      |> Enum.each(fn {s, position} ->
        Repo.update_all(where(Segment, id: ^s.id), set: [position: position])
      end)
    end

    :ok
  end
end
