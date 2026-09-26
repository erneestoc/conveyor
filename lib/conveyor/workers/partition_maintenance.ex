defmodule Conveyor.Workers.PartitionMaintenance do
  @moduledoc """
  Hourly job: create upcoming segment partitions and drop those past raw retention
  (`RETENTION_RAW_DAYS`), keeping any day the raw archive has not finished with.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

  alias Conveyor.Storage.Partitions

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Partitions.ensure()
    retention_days = Application.get_env(:conveyor, :retention_raw_days, 14)
    cutoff = Date.add(Date.utc_today(), -retention_days)

    # With the raw archive on, a day whose finished builds are not all archived yet stays:
    # dropping it would lose their events (docs/spec/Archive.tla).
    keep? =
      if Conveyor.RawArchive.enabled?(),
        do: &Conveyor.RawArchive.holds_unarchived?/1,
        else: fn _day -> false end

    dropped = Partitions.drop_before(cutoff, keep?)
    {:ok, %{dropped: dropped}}
  end
end
