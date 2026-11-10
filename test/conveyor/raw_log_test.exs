defmodule Conveyor.RawLogTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.RawLog

  test "objects are registered, written, read by range and swept by age" do
    key = RawLog.new_key(3)
    assert key =~ ~r"^rawlog/[^/]+/3/[0-9a-v]{10}[a-z2-7]{8}$"
    assert :ok = RawLog.put(key, ["hello ", "raw ", "log"])
    assert {:ok, "raw"} = RawLog.get_range(key, 6, 3)
    assert {:error, :short_read} = RawLog.get_range(key, 6, 30)
    assert {:error, :not_found} = RawLog.get_range("rawlog/none/0/x", 0, 1)

    # Not old enough: nothing swept; then everything registered before "now" goes.
    assert %{deleted: 0} = RawLog.sweep(DateTime.add(DateTime.utc_now(), -3600, :second))
    assert {:ok, _} = RawLog.get_range(key, 0, 5)
    assert %{deleted: 1} = RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second))
    assert {:error, :not_found} = RawLog.get_range(key, 0, 1)
    assert %{deleted: 0} = RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second))
    refute RawLog.blob_mode?()
    assert RawLog.flush_ms() == 1000
    assert RawLog.fsync?()
  end

  test "the raw log goes through whatever adapter is configured, and its failures are counted" do
    previous = Application.get_env(:conveyor, Conveyor.Blobs)
    dir = Path.join(System.tmp_dir!(), "conveyor-rawlog-#{System.unique_integer([:positive])}")
    switches = [:flaky_object_puts, :flaky_object_reads, :flaky_object_deletes]

    on_exit(fn ->
      Application.put_env(:conveyor, Conveyor.Blobs, previous)
      Enum.each(switches, &Application.delete_env(:conveyor, &1))
      File.rm_rf(dir)
    end)

    # An adapter module that is neither Disk nor S3 (this raised CaseClauseError).
    Application.put_env(:conveyor, Conveyor.Blobs,
      adapter: Conveyor.Blobs.Flaky,
      opts: [dir: dir]
    )

    test = self()
    handler = "rawlog-errors-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:conveyor, :blobs, :errors],
      fn _, _, %{op: op}, _ -> send(test, {:blob_error, op}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    key = RawLog.new_key("flaky")
    assert :ok = RawLog.put(key, "bytes")
    assert {:ok, "bytes"} = RawLog.get_range(key, 0, 5)

    Enum.each(switches, &Application.put_env(:conveyor, &1, true))
    assert {:error, :store_unavailable} = RawLog.put(RawLog.new_key("flaky"), "bytes")
    assert_received {:blob_error, :put_object}
    assert {:error, :store_unavailable} = RawLog.get_range(key, 0, 5)
    assert_received {:blob_error, :get_range}

    # A sweep that cannot delete keeps the rows (two: the failed put registered its key).
    later = DateTime.add(DateTime.utc_now(), 1, :second)
    assert %{deleted: 0, failed: 2} = RawLog.sweep(later)
    assert_received {:blob_error, :delete_objects}
    assert Repo.aggregate(from(o in "raw_log_objects"), :count) == 2

    Enum.each(switches, &Application.delete_env(:conveyor, &1))
    assert %{deleted: 2, failed: 0} = RawLog.sweep(later)
  end
end
