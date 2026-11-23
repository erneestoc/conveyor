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
    now = ExecLog.now()

    per_project =
      for project <- Projects.list_projects(include_archived: true) do
        days = Projects.retention_days(project) || default_days
        cutoff = DateTime.add(now, -days, :day)
        deleted = delete_before(project, cutoff, 0)
        if deleted > 0, do: Invocations.rebuild_tag_keys!(project.id)
        Conveyor.Metrics.Rollup.prune!(project.id, cutoff)
        spawn_cutoff = ExecLog.retention_cutoff(project, now)
        expired = ExecLog.expire_before(project, spawn_cutoff)
        Conveyor.Rbe.Fleet.prune!(project.id, cutoff)
        {project.slug, %{deleted: deleted, cutoff: cutoff, expired: expired}}
      end

    pruned_keys = prune_action_keys(now)

    deleted = per_project |> Enum.map(fn {_, r} -> r.deleted end) |> Enum.sum()
    pruned_inputs = ExecLog.prune_orphan_inputs(now)

    {:ok,
     %{
       deleted: deleted,
       pruned_inputs: pruned_inputs,
       pruned_keys: pruned_keys,
       projects: Map.new(per_project)
     }}
  end

  # Action keys leave two days after the spawn retention of their scope: by then every
  # execution of the key belongs to a build whose spawns are gone and whose hours are
  # frozen. A group keeps its keys as long as its longest-keeping member; rows of a scope
  # that no longer exists leave after the global retention.
  defp prune_action_keys(now) do
    alias Conveyor.ExecLog.Keys
    alias Conveyor.Rbe.Groups

    projects = Projects.list_projects(include_archived: true)
    # By the execution-log retention, not by how long the spawn rows are kept: an
    # analysis-only project drops rows after days and keeps its keys (PLAN §27.11).
    cutoff = fn project -> DateTime.add(ExecLog.key_retention_cutoff(project, now), -2, :day) end
    own = projects |> Enum.map(&Keys.prune!(&1.id, cutoff.(&1))) |> Enum.sum()

    grouped =
      projects
      |> Enum.group_by(&Groups.name/1)
      |> Map.delete(nil)
      |> Enum.map(fn {name, members} ->
        case Groups.get_by_name(name) do
          nil ->
            0

          group ->
            Keys.prune!(Groups.scope(group), members |> Enum.map(cutoff) |> Enum.min(DateTime))
        end
      end)
      |> Enum.sum()

    default = Application.get_env(:conveyor, :retention_spawn_days, 30)
    orphans = Keys.prune_orphans!(Groups.live_scopes(), DateTime.add(now, -default - 2, :day))
    own + grouped + orphans
  end

  @doc "Deletes a project's builds that started (or, lacking a start, were inserted) before `cutoff`."
  @spec delete_before(Project.t(), DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def delete_before(%Project{id: project_id} = project, cutoff, acc) do
    idle_ms = Conveyor.Ingest.idle_timeout_ms()
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
