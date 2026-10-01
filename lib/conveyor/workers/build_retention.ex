defmodule Conveyor.Workers.BuildRetention do
  @moduledoc """
  Daily job: deletes builds older than each project's retention (`RETENTION_DAYS`, default
  90, unless the project sets its own days) in small batches. Targets, tests, actions,
  metrics, named sets and artifact rows cascade with the build; raw event and log segments
  are dropped by partition after `RETENTION_RAW_DAYS` (`Conveyor.Workers.PartitionMaintenance`)
  and blobs nothing references any more by `Conveyor.Workers.BlobMaintenance`. Execution-log
  spawns go earlier, after the project's spawn retention (`RETENTION_SPAWN_DAYS`), and the
  input lists nothing references any more are pruned. Tag facet counts are rebuilt for
  every project that lost builds.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  alias Conveyor.{ExecLog, Invocations, Projects, Repo}
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
        Conveyor.Metrics.Rollup.prune!(project.id, cutoff)
        expired = ExecLog.expire_before(project, ExecLog.retention_cutoff(project, now))
        {project.slug, %{deleted: deleted, cutoff: cutoff, expired: expired}}
      end

    deleted = per_project |> Enum.map(fn {_, r} -> r.deleted end) |> Enum.sum()
    pruned_inputs = ExecLog.prune_orphan_inputs(now)
    {:ok, %{deleted: deleted, pruned_inputs: pruned_inputs, projects: Map.new(per_project)}}
  end

  @doc "Deletes a project's builds that started (or, lacking a start, were inserted) before `cutoff`."
  @spec delete_before(Project.t(), DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def delete_before(%Project{id: project_id} = project, cutoff, acc) do
    idle_ms = Conveyor.Ingest.config(:idle_timeout_ms, 600_000)
    recent = DateTime.add(DateTime.utc_now(), -2 * idle_ms, :millisecond)

    ids =
      Repo.all(
        from i in Invocation,
          where: i.project_id == ^project_id,
          where: coalesce(i.started_at, i.inserted_at) < ^cutoff,
          # A build whose row changed within the idle window may still be streaming (or
          # about to resume); deleting it would fence the worker and leave an empty row
          # behind when the client retries (docs/spec/Retention.tla).
          where: i.status not in ["in_progress", "disconnected"] or i.updated_at < ^recent,
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
