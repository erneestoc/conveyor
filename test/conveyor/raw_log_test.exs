defmodule Conveyor.RawLogTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.RawLog

  test "objects are registered, written, read by range and swept by age" do
    key = RawLog.new_key(3)
    assert key =~ ~r"^rawlog/[^/]+/3/[0-9a-v]{10}[a-z2-7]{8}$"
    assert :ok = RawLog.put(key, ["hello ", "raw ", "log"])
    assert {:ok, "raw"} = RawLog.get_range(key, 6, 3)
    assert {:error, :short_read} = RawLog.get_range(key, 6, 30)
    assert {:error, :enoent} = RawLog.get_range("rawlog/none/0/x", 0, 1)

    # Not old enough: nothing swept; then everything registered before "now" goes.
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), -3600, :second)) == 0
    assert {:ok, _} = RawLog.get_range(key, 0, 5)
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) == 1
    assert {:error, :enoent} = RawLog.get_range(key, 0, 1)
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) == 0
    refute RawLog.blob_mode?()
    assert RawLog.flush_ms() == 1000
  end
end
