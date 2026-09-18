defmodule Conveyor.Workers.PartitionMaintenanceTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Storage.Partitions
  alias Conveyor.Workers.PartitionMaintenance

  test "creates upcoming partitions and drops those past retention" do
    old = Date.add(Date.utc_today(), -400)
    Partitions.ensure_day(old)
    assert {:ok, %{dropped: dropped}} = PartitionMaintenance.perform(%Oban.Job{})
    assert Partitions.partition_name("event_segments", old) in dropped

    assert Partitions.partition_name("event_segments", Date.add(Date.utc_today(), 3)) in Partitions.partition_names(
             "event_segments"
           )
  end
end
