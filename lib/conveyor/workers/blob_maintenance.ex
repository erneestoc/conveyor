defmodule Conveyor.Workers.BlobMaintenance do
  @moduledoc """
  Daily job: drop CAS uploads whose TTL passed without an invocation pinning them, and
  pinned blobs whose invocations retention has since deleted (nothing references them).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, %{pruned: Conveyor.Blobs.prune_expired(), orphans: Conveyor.Blobs.prune_orphans()}}
  end
end
