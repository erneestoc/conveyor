defmodule Conveyor.Workers.RawLogSweepTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.Storage.Partitions

  # The test database keeps the partitions of its first boot; the sweep stops at the
  # oldest one, so each test clears the days older than the object it ages (rolled back
  # with the sandbox transaction).
  setup do
    Partitions.drop_before(Date.add(Date.utc_today(), -39))
    :ok
  end

  test "sweeps only objects older than the raw retention plus a day" do
    key = Conveyor.RawLog.new_key(0)
    :ok = Conveyor.RawLog.put(key, "x")
    assert {:ok, %{swept: 0}} = perform_job(Conveyor.Workers.RawLogSweep, %{})

    Conveyor.Repo.update_all(from(o in "raw_log_objects", where: o.key == ^key),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -40, :day)]
    )

    assert {:ok, %{swept: 1}} = perform_job(Conveyor.Workers.RawLogSweep, %{})
  end

  test "keeps an object as long as a segment partition of its day or earlier exists" do
    old_day = Date.add(Date.utc_today(), -45)
    Partitions.ensure_day(old_day)

    key = Conveyor.RawLog.new_key(0)
    :ok = Conveyor.RawLog.put(key, "x")

    Conveyor.Repo.update_all(from(o in "raw_log_objects", where: o.key == ^key),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -40, :day)]
    )

    # the partition of a day before the object's registration is still there (its drop
    # ran late, or the archive kept it): the object may be referenced from it
    assert {:ok, %{swept: 0}} = perform_job(Conveyor.Workers.RawLogSweep, %{})

    Partitions.drop_before(Date.add(old_day, 1))
    assert {:ok, %{swept: 1}} = perform_job(Conveyor.Workers.RawLogSweep, %{})
  end
end
