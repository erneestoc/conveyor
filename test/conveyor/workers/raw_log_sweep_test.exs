defmodule Conveyor.Workers.RawLogSweepTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.RawLog
  alias Conveyor.Storage.Partitions
  alias Conveyor.Workers.RawLogSweep

  # The test database keeps the partitions of its first boot; the sweep stops at the
  # oldest one, so each test clears the days older than the object it ages (rolled back
  # with the sandbox transaction).
  setup do
    Partitions.drop_before(Date.add(Date.utc_today(), -39))
    previous = Application.get_env(:conveyor, RawLog)
    Application.put_env(:conveyor, RawLog, Keyword.put(previous || [], :fsync, false))
    on_exit(fn -> Application.put_env(:conveyor, RawLog, previous) end)
    :ok
  end

  defp root, do: Conveyor.Blobs.adapter() |> elem(1) |> Keyword.fetch!(:dir)

  defp age!(keys, days) do
    Repo.update_all(from(o in "raw_log_objects", where: o.key in ^keys),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -days, :day)]
    )
  end

  defp registered(keys),
    do: Repo.all(from(o in "raw_log_objects", where: o.key in ^keys, select: o.key))

  # Rows of objects that are not in the store: what a crash between the row and the bytes
  # leaves, and enough of them to count without writing as many files.
  defp register!(shard, n) do
    keys = for i <- 1..n, do: "rawlog/sweep-test/#{shard}/#{i}"
    at = DateTime.add(DateTime.utc_now(), -40, :day)

    keys
    |> Enum.map(&%{key: &1, inserted_at: at})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all("raw_log_objects", &1))

    keys
  end

  test "sweeps only objects older than the raw retention plus a day" do
    key = RawLog.new_key(0)
    :ok = RawLog.put(key, "x")
    assert {:ok, %{deleted: 0}} = perform_job(RawLogSweep, %{})
    assert %{objects: 0, overdue_seconds: 0} = Conveyor.RawStore.expiry_backlog()

    age!([key], 40)
    assert %{objects: 1, overdue_seconds: late} = Conveyor.RawStore.expiry_backlog()
    assert late > 0

    assert {:ok, %{deleted: 1, failed: 0, remaining?: false}} = perform_job(RawLogSweep, %{})
    assert {:error, _} = RawLog.get_range(key, 0, 1)
    refute_enqueued(worker: RawLogSweep)
  end

  test "keeps an object as long as a segment partition of its day or earlier exists" do
    old_day = Date.add(Date.utc_today(), -45)
    Partitions.ensure_day(old_day)

    key = RawLog.new_key(0)
    :ok = RawLog.put(key, "x")
    age!([key], 40)

    # the partition of a day before the object's registration is still there (its drop
    # ran late, or the archive kept it): the object may be referenced from it
    assert {:ok, %{deleted: 0}} = perform_job(RawLogSweep, %{})

    Partitions.drop_before(Date.add(old_day, 1))
    assert {:ok, %{deleted: 1}} = perform_job(RawLogSweep, %{})
  end

  test "one run sweeps everything that is due, page after page, at a pace above the write rate" do
    # 3,000 objects with bytes and 9,500 rows without (the sweep used to stop at 10,000 a
    # day, one object and one statement at a time).
    with_bytes = for _ <- 1..3_000, do: RawLog.new_key("pace")
    on_exit(fn -> File.rm_rf(Path.dirname(Path.join(root(), hd(with_bytes)))) end)
    Enum.each(with_bytes, &(:ok = RawLog.put(&1, "bytes")))
    age!(with_bytes, 40)
    orphans = register!("orphans", 9_500)

    {micros, {:ok, result}} = :timer.tc(fn -> perform_job(RawLogSweep, %{}) end)
    assert %{deleted: 12_500, failed: 0, remaining?: false} = result
    assert registered(with_bytes ++ orphans) == []
    assert File.ls!(Path.dirname(Path.join(root(), hd(with_bytes)))) == []
    # A node writes at most a few hundred objects a second; the disk store deletes
    # thousands (measured: PLAN §26.5).
    assert 12_500 / (micros / 1_000_000) > 1_000
  end

  @tag :capture_log
  test "an object the store refuses to delete keeps its row, is counted, and stalls nothing" do
    [refused | rest] = keys = for _ <- 1..5, do: RawLog.new_key("refused")
    on_exit(fn -> File.rm_rf(Path.dirname(Path.join(root(), refused))) end)
    Enum.each(rest, &(:ok = RawLog.put(&1, "bytes")))
    # A directory with something in it cannot be unlinked: the delete fails.
    File.mkdir_p!(Path.join([root(), refused, "in-the-way"]))
    Repo.insert_all("raw_log_objects", [%{key: refused}])
    age!(keys, 40)

    test = self()
    handler = "sweep-failed-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:conveyor, :raw_log, :sweep_failed],
      fn _, %{count: 1}, %{key: key}, _ -> send(test, {:sweep_failed, key}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Pages of two: the refused key is in the first, the run goes on past it.
    assert %{deleted: 4, failed: 1, remaining?: false} =
             Conveyor.RawStore.expire_objects(DateTime.utc_now(), page: 2)

    assert_received {:sweep_failed, ^refused}
    assert registered(keys) == [refused]

    # The next run tries it again, and succeeds once the store lets it.
    File.rm_rf!(Path.join(root(), refused))
    assert %{deleted: 1, failed: 0} = Conveyor.RawStore.expire_objects()
    assert registered(keys) == []
  end

  test "a run that reaches its deadline enqueues its own continuation" do
    previous = Application.get_env(:conveyor, RawLogSweep)
    Application.put_env(:conveyor, RawLogSweep, deadline_ms: 0, page: 10)
    on_exit(fn -> Application.put_env(:conveyor, RawLogSweep, previous || []) end)
    keys = register!("deadline", 25)

    assert {:ok, %{deleted: 10, remaining?: true}} = perform_job(RawLogSweep, %{})
    assert_enqueued(worker: RawLogSweep, args: %{continued: 1})

    assert {:ok, %{deleted: 10, remaining?: true}} = perform_job(RawLogSweep, %{continued: 1})
    assert_enqueued(worker: RawLogSweep, args: %{continued: 2})

    assert {:ok, %{deleted: 5, remaining?: false}} = perform_job(RawLogSweep, %{continued: 2})
    assert registered(keys) == []
  end
end
