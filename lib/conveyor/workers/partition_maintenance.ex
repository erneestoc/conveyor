defmodule Conveyor.Workers.PartitionMaintenance do
  @moduledoc "Hourly job: create upcoming segment partitions and drop those past raw retention."
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

  alias Conveyor.Storage.Partitions

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Partitions.ensure()
    retention_days = Application.get_env(:conveyor, :retention_raw_days, 14)
    dropped = Partitions.drop_before(Date.add(Date.utc_today(), -retention_days))
    {:ok, %{dropped: dropped}}
  end
end
