defmodule Conveyor.Storage.PartitionsTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Storage.Partitions

  test "ensures, lists and drops daily partitions" do
    day = ~D[2000-01-05]
    assert :ok = Partitions.ensure(1, day)
    names = Partitions.partition_names("event_segments")
    assert "event_segments_20000104" in names and "event_segments_20000106" in names
    assert :ok = Partitions.ensure_day(~D[2000-02-01])
    assert "log_segments_20000201" in Partitions.partition_names("log_segments")

    dropped = Partitions.drop_before(~D[2000-01-06])
    assert "event_segments_20000104" in dropped and "log_segments_20000105" in dropped
    refute "event_segments_20000106" in dropped
    refute "event_segments_20000104" in Partitions.partition_names("event_segments")

    assert Partitions.drop_before(~D[2000-03-01]) |> Enum.sort() ==
             ~w(event_segments_20000106 event_segments_20000201 log_segments_20000106 log_segments_20000201)

    assert Partitions.partition_name("event_segments", ~D[2026-09-18]) ==
             "event_segments_20260918"
  end

  test "storage boot is idempotent and swallows failures" do
    assert :ok = Conveyor.Storage.boot()
    assert :ok = Conveyor.Storage.boot()
  end
end
