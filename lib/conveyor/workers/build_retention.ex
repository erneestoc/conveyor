defmodule Conveyor.Workers.BuildRetention do
  @moduledoc """
  Daily job: deletes builds older than `RETENTION_DAYS` (default 90) in small batches.
  Targets, tests, actions, metrics, named sets and artifact rows cascade with the build;
  raw event and log segments are dropped by partition after `RETENTION_RAW_DAYS`
  (`Conveyor.Workers.PartitionMaintenance`) and unpinned blobs by
  `Conveyor.Workers.BlobMaintenance`. Tag facet counts are rebuilt afterwards.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  alias Conveyor.{Invocations, Repo}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Projects.Project

  @batch 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:conveyor, :retention_days, 90)
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    deleted = delete_before(cutoff, 0)

    if deleted > 0 do
      for id <- Repo.all(from p in Project, select: p.id), do: Invocations.rebuild_tag_keys!(id)
    end

    {:ok, %{deleted: deleted, cutoff: cutoff}}
  end

  @doc "Deletes builds that started (or, lacking a start, were inserted) before `cutoff`."
  @spec delete_before(DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def delete_before(cutoff, acc) do
    ids =
      Repo.all(
        from i in Invocation,
          where: coalesce(i.started_at, i.inserted_at) < ^cutoff,
          select: i.id,
          limit: @batch
      )

    case ids do
      [] ->
        acc

      ids ->
        {n, _} = Repo.delete_all(from i in Invocation, where: i.id in ^ids)
        delete_before(cutoff, acc + n)
    end
  end
end
