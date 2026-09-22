defmodule Conveyor.Workers.BuildRetention do
  @moduledoc """
  Daily job: deletes builds older than each project's retention (`RETENTION_DAYS`, default
  90, unless the project sets its own days) in small batches. Targets, tests, actions,
  metrics, named sets and artifact rows cascade with the build; raw event and log segments
  are dropped by partition after `RETENTION_RAW_DAYS` (`Conveyor.Workers.PartitionMaintenance`)
  and blobs nothing references any more by `Conveyor.Workers.BlobMaintenance`. Tag facet
  counts are rebuilt for every project that lost builds.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  alias Conveyor.{Invocations, Projects, Repo}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Projects.Project

  @batch 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    default_days = Application.get_env(:conveyor, :retention_days, 90)
    now = DateTime.utc_now()

    per_project =
      for project <- Projects.list_projects(include_archived: true) do
        days = Projects.retention_days(project) || default_days
        cutoff = DateTime.add(now, -days, :day)
        deleted = delete_before(project, cutoff, 0)
        if deleted > 0, do: Invocations.rebuild_tag_keys!(project.id)
        {project.slug, %{deleted: deleted, cutoff: cutoff}}
      end

    deleted = per_project |> Enum.map(fn {_, r} -> r.deleted end) |> Enum.sum()
    {:ok, %{deleted: deleted, projects: Map.new(per_project)}}
  end

  @doc "Deletes a project's builds that started (or, lacking a start, were inserted) before `cutoff`."
  @spec delete_before(Project.t(), DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def delete_before(%Project{id: project_id} = project, cutoff, acc) do
    ids =
      Repo.all(
        from i in Invocation,
          where: i.project_id == ^project_id,
          where: coalesce(i.started_at, i.inserted_at) < ^cutoff,
          select: i.id,
          limit: @batch
      )

    case ids do
      [] ->
        acc

      ids ->
        {n, _} = Repo.delete_all(from i in Invocation, where: i.id in ^ids)
        delete_before(project, cutoff, acc + n)
    end
  end
end
