defmodule Conveyor.Workers.PartitionMaintenance do
  @moduledoc """
  Hourly job: create upcoming segment partitions and drop those past raw retention
  (`RETENTION_RAW_DAYS`), keeping any day the raw archive has not finished with. Which
  days may go is `Conveyor.RawStore.Expiry`'s rule 1.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

  alias Conveyor.Storage.Partitions

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Partitions.ensure()
    {:ok, %{dropped: Conveyor.RawStore.expire_partitions()}}
  end
end
