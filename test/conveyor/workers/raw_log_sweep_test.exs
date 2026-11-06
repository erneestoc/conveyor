defmodule Conveyor.Workers.RawLogSweepTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  test "sweeps only objects older than the raw retention plus a day" do
    key = Conveyor.RawLog.new_key(0)
    :ok = Conveyor.RawLog.put(key, "x")
    assert {:ok, %{swept: 0}} = perform_job(Conveyor.Workers.RawLogSweep, %{})

    Conveyor.Repo.update_all(from(o in "raw_log_objects", where: o.key == ^key),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -40, :day)]
    )

    assert {:ok, %{swept: 1}} = perform_job(Conveyor.Workers.RawLogSweep, %{})
  end
end
