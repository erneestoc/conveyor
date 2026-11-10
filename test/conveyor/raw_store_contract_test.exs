defmodule Conveyor.RawStoreContractTest do
  @moduledoc """
  `Conveyor.RawStore`: the bytes appended are the bytes read, in every form (payload rows,
  byte ranges of raw-log objects, archived blobs), across every transition (compaction,
  the partition drop and the object sweep at each clock) and on every adapter the gate
  reaches; `raw_store_s3_test.exs` runs the same scenarios against a real S3-compatible
  store. Failures are injected at the adapter seam (`Blobs.Flaky`), never by reaching
  into the store's tables.
  """
  use ConveyorWeb.LiveCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  import Conveyor.IngestCase, only: [raw_log_mode!: 2]
  import Conveyor.RawStoreContract
  import Ecto.Query

  alias Conveyor.{Blobs, RawStore, Repo}
  alias Conveyor.Blobs.{Counting, Disk, Flaky, OneShot}
  alias Conveyor.Ingest.Verify
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Workers.{ArchiveRaw, PartitionMaintenance, RawLogSweep}

  setup do
    switches =
      ~w(flaky_blob_puts flaky_blob_deletes flaky_object_puts flaky_object_reads flaky_object_deletes)a

    on_exit(fn -> Enum.each(switches, &Application.delete_env(:conveyor, &1)) end)
    %{project: Conveyor.Projects.ensure_default_project!(), ctx: context()}
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 2, :day)
  defp raw_blobs, do: Repo.aggregate(from(b in Blobs.Blob, where: b.source == "raw"), :count)

  describe "bytes appended = bytes read" do
    for adapter <- [Disk, OneShot, Flaky],
        {name, modes} <- [
          postgres: [:postgres],
          blob: [:blob],
          "mode changed mid-build": [:postgres, :blob]
        ] do
      test "#{inspect(adapter)}, #{name}: payload or range, archived, partition dropped, objects swept",
           %{project: project} do
        adapter!(unquote(adapter))
        assert :ok = lifecycle!(project, unquote(modes))
      end
    end

    for {name, modes} <- [
          postgres: [:postgres],
          blob: [:blob],
          "mode changed mid-build": [:blob, :postgres]
        ] do
      test "#{name}, no compaction: the partition goes after raw retention, the objects after the partition",
           %{project: project} do
        assert :ok = hot_expiry!(project, unquote(modes))
      end
    end

    test "a build of megabytes reads the same from segments, from ranges and from its blobs", %{
      project: project
    } do
      compaction!(true)
      text = String.duplicate("a log line like the one before it\n", 30_000)

      for mode <- [:postgres, :blob] do
        a = build!(project)
        [a] = append!([{a, [:crypto.strong_rand_bytes(300_000), "small"], text}], mode)
        [a] = append!([{a, [String.duplicate("x", 400_000)], text}], mode)
        a = finish!(a)
        assert_reads!(a)
        assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
        assert_reads!(a)
      end
    end

    test "a build that is still running reads what has been committed, as one consistent log size",
         %{project: project} do
      a = build!(project)
      assert_reads!(a)
      [a] = append!([{a, ["one"], "first\n"}], :blob)
      inv = assert_reads!(a)

      # The size announced is the size streamed, even when more arrives before the stream
      # is read (the log viewer splices live appends by this offset).
      log = RawStore.log(inv)
      [a] = append!([{a, ["two"], "second\n"}], :postgres)
      assert log.bytes == 6
      assert log.chunks |> Enum.to_list() |> IO.iodata_to_binary() == "first\n"
      assert_reads!(a)
    end

    test "raw-log objects live under the reserved prefix, outside every project's", %{
      project: project
    } do
      {Disk, opts} = Blobs.adapter()
      before = File.ls!(opts[:dir])
      a = build!(project)
      append!([{a, ["bytes"], "log\n"}], :blob, "prefix")
      assert (File.ls!(opts[:dir]) -- before) -- ["rawlog"] == []
      assert "rawlog" in File.ls!(opts[:dir])
      assert "rawlog" in Conveyor.Projects.Project.reserved_prefixes()
    end
  end

  describe "the object store fails" do
    setup do
      adapter!(Flaky)
      compaction!(true)
    end

    @tag :capture_log
    test "a put that fails appends nothing; the same group goes through when the store is back",
         %{project: project} do
      a = build!(project)
      prepared = prepare([{a, ["m1", "m2"], "log\n"}], :blob)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:conveyor, :raw_log, :put_failed],
          [:conveyor, :blobs, :errors]
        ])

      Application.put_env(:conveyor, :flaky_object_puts, true)
      assert {:error, message} = commit(prepared)
      assert message =~ "raw log put"

      assert_received {[:conveyor, :raw_log, :put_failed], ^ref, %{count: 1},
                       %{shard: "contract"}}

      assert_received {[:conveyor, :blobs, :errors], ^ref, %{count: 1}, %{op: :put_object}}
      # Nothing was acknowledged, nothing is readable.
      assert_reads!(a)

      Application.delete_env(:conveyor, :flaky_object_puts)
      assert {:ok, [a]} = commit(prepared)
      assert_reads!(a)
      # The failed try and the retry are one object: one to expire.
      RawStore.expire_partitions(Date.add(Date.utc_today(), raw_days() + 1))
      clock = DateTime.add(DateTime.utc_now(), raw_days() + 2, :day)
      assert %{objects: 1} = RawStore.expiry_backlog(clock)
    end

    @tag :capture_log
    test "a ranged read that fails is the reader's error, never fewer bytes; nothing is damaged",
         %{project: project} do
      {a, b} = two_builds!(project, [:blob])
      inv = assert_reads!(a)
      ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :blobs, :errors]])

      Application.put_env(:conveyor, :flaky_object_reads, true)
      assert_raise RuntimeError, ~r/raw log .*store_unavailable/, fn -> RawStore.frames(inv) end
      assert_received {[:conveyor, :blobs, :errors], ^ref, %{count: 1}, %{op: :get_range}}
      assert_raise RuntimeError, ~r/raw log/, fn -> Enum.to_list(RawStore.bep(inv)) end
      assert_raise RuntimeError, ~r/raw log/, fn -> Enum.to_list(RawStore.log(inv).chunks) end
      assert_raise RuntimeError, ~r/raw log/, fn -> RawStore.events_page(inv, 1, 2) end
      assert_raise RuntimeError, ~r/raw log/, fn -> RawStore.audit(inv) end

      # Compaction reads the same way: it fails, references nothing and leaves the build as it was.
      assert {:error, %RuntimeError{message: "raw log" <> _}} = RawStore.compact(inv.id, later())
      assert Repo.get!(Invocation, inv.id).raw_blob == nil

      Application.delete_env(:conveyor, :flaky_object_reads)
      assert_reads!(a)
      assert {:ok, :archived} = RawStore.compact(inv.id, later())
      assert_reads!(a)
      assert_reads!(b)
    end

    @tag :capture_log
    test "a delete that fails keeps the object registered; the next run deletes it", %{
      project: project
    } do
      compaction!(false)
      {a, _b} = two_builds!(project, [:blob])
      today = DateTime.to_date(a.inv.inserted_at)
      RawStore.expire_partitions(Date.add(today, raw_days() + 1))
      clock = DateTime.add(DateTime.utc_now(), raw_days() + 2, :day)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:conveyor, :raw_log, :sweep_failed],
          [:conveyor, :blobs, :errors]
        ])

      Application.put_env(:conveyor, :flaky_object_deletes, true)
      assert %{deleted: 0, failed: 4, remaining?: false} = RawStore.expire_objects(clock)

      assert_received {[:conveyor, :raw_log, :sweep_failed], ^ref, %{count: 1},
                       %{reason: :store_unavailable}}

      assert_received {[:conveyor, :blobs, :errors], ^ref, %{count: 1}, %{op: :delete_objects}}
      assert %{objects: 4, overdue_seconds: late} = RawStore.expiry_backlog(clock)
      assert late > 0

      # A refused key is stepped over, not retried within the run: pages of one still end.
      assert %{deleted: 0, failed: 4} = RawStore.expire_objects(clock, page: 1)

      Application.delete_env(:conveyor, :flaky_object_deletes)
      assert %{deleted: 4, failed: 0} = RawStore.expire_objects(clock, page: 3)
      assert %{objects: 0} = RawStore.expiry_backlog(clock)
    end

    @tag :capture_log
    test "a store outage fails compaction; the build keeps reading from its segments and a later run archives",
         %{project: project} do
      {a, _b} = two_builds!(project, [:postgres])
      ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :raw_archive, :failures]])

      Application.put_env(:conveyor, :flaky_blob_puts, true)
      assert {:error, :store_unavailable} = RawStore.compact(a.inv.id, later())
      assert_receive {[:conveyor, :raw_archive, :failures], ^ref, %{count: 1}, %{reason: :error}}
      assert_reads!(a)
      # The day is still held back for it.
      today = DateTime.to_date(a.inv.inserted_at)

      refute "event_segments_#{Calendar.strftime(today, "%Y%m%d")}" in RawStore.expire_partitions(
               Date.add(today, 60)
             )

      Application.delete_env(:conveyor, :flaky_blob_puts)
      assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
      assert_reads!(a)
    end

    @tag :capture_log
    test "a run whose reads fail archives nothing, counts every build as failed and leaves them due",
         %{project: project} do
      {a, b} = two_builds!(project, [:blob])
      Application.put_env(:conveyor, :flaky_object_reads, true)
      assert %{archived: 0, failed: 2, remaining?: false} = RawStore.compact_due(later())
      Application.delete_env(:conveyor, :flaky_object_reads)
      assert_reads!(a)
      assert %{archived: 2, failed: 0} = RawStore.compact_due(later())
      assert_reads!(a)
      assert_reads!(b)
    end

    test "an archived build whose blob is gone reads as an error, never as an empty build", %{
      project: project
    } do
      {a, _b} = two_builds!(project, [:postgres])
      assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
      inv = assert_reads!(a)
      for digest <- [inv.raw_blob, inv.log_blob], do: :ok = Blobs.delete(project, digest)

      assert_raise RuntimeError, ~r/archived build/, fn -> RawStore.frames(inv) end
      assert_raise RuntimeError, ~r/archived build/, fn -> RawStore.log(inv) end
      assert_raise RuntimeError, ~r/archived build/, fn -> RawStore.audit(inv) end
    end
  end

  describe "compaction (docs/spec/Archive.tla)" do
    setup do
      compaction!(true)
    end

    test "archived means the events blob is referenced: a status without it reads from the segments",
         %{project: project} do
      {a, _b} = two_builds!(project, [:postgres, :blob])

      Repo.update_all(from(i in Invocation, where: i.id == ^a.inv.id),
        set: [raw_status: "archived"]
      )

      assert_reads!(a)
    end

    test "the events object is a zstd --build_event_binary_file with the BEP dictionary", %{
      project: project
    } do
      {a, _b} = two_builds!(project, [:blob])
      assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
      inv = assert_reads!(a)
      {:ok, stored} = Blobs.read(project, inv.raw_blob)
      assert {:ok, %{dictID: 1}} = :zstd.get_frame_header(stored)

      assert %{content_type: "application/x-bep+zstd", source: "raw", expires_at: nil} =
               Blobs.get(project, inv.raw_blob)

      {:ok, log} = Blobs.read(project, inv.log_blob)
      assert {:ok, %{dictID: 0}} = :zstd.get_frame_header(log)
    end

    test "the loser of two archivers keeps the winner's blobs", %{project: project} do
      {a, _b} = two_builds!(project, [:blob])
      stale = a.inv
      assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
      inv = assert_reads!(a)

      # A second node loaded the row before the first archived it: same content, same
      # digests; its conditional update finds nothing and its discard leaves them alone.
      assert {:ok, :lost} = RawStore.compact(stale, later())
      assert Blobs.exists?(project, inv.raw_blob) and Blobs.exists?(project, inv.log_blob)
      assert_reads!(a)

      # Orphan pruning keeps what a build references.
      assert Blobs.prune_orphans(DateTime.add(DateTime.utc_now(), 2, :hour)) == 0
      assert_reads!(a)
    end

    test "two archivers at once: one wins, the build reads the same", %{project: project} do
      {a, _b} = two_builds!(project, [:postgres])

      outcomes =
        [a.inv, a.inv, a.inv.id]
        |> Enum.map(fn arg -> Task.async(fn -> RawStore.compact(arg, later()) end) end)
        |> Task.await_many(30_000)

      assert Enum.count(outcomes, &(&1 == {:ok, :archived})) == 1

      assert Enum.all?(
               outcomes,
               &(&1 in [{:ok, :archived}, {:ok, :lost}, {:ok, :already_archived}])
             )

      assert_reads!(a)
      assert raw_blobs() == 2
    end

    test "a build deleted while it was being archived leaves no blob behind", %{project: project} do
      {a, _b} = two_builds!(project, [:blob])
      Repo.delete_all(from i in Invocation, where: i.id == ^a.inv.id)
      assert {:ok, :lost} = RawStore.compact(a.inv, later())
      assert raw_blobs() == 0
      assert {:ok, :not_found} = RawStore.compact(a.inv.id, later())
      assert {:ok, :not_found} = RawStore.compact(:gone, later())
    end

    test "a crash between the puts and the reference leaves orphans the prune removes; the next run archives",
         %{project: project} do
      {a, _b} = two_builds!(project, [:postgres])

      # The transaction that references the blobs dies.
      Repo.query!("""
      CREATE FUNCTION conveyor_test_no_reference() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.raw_status = 'archived' THEN RAISE EXCEPTION 'injected' USING ERRCODE = '57P01'; END IF;
        RETURN NEW;
      END $$
      """)

      Repo.query!("""
      CREATE TRIGGER conveyor_test_no_reference BEFORE UPDATE ON invocations
      FOR EACH ROW EXECUTE FUNCTION conveyor_test_no_reference()
      """)

      assert_raise Postgrex.Error, fn -> RawStore.compact(a.inv.id, later()) end
      Repo.query!("DROP TRIGGER conveyor_test_no_reference ON invocations")
      assert raw_blobs() == 2
      assert_reads!(a)

      assert Blobs.prune_orphans(DateTime.add(DateTime.utc_now(), 2, :hour)) == 2
      assert raw_blobs() == 0
      assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
      assert_reads!(a)
    end

    @tag :capture_log
    test "a build whose stored bytes do not match its row is skipped: kept as it is, and it frees its day",
         %{project: project} do
      {a, b} = two_builds!(project, [:blob])
      today = DateTime.to_date(a.inv.inserted_at)
      # Rows that claim more than was committed (what a bug in the pipeline would leave).
      Repo.update_all(from(i in Invocation, where: i.id == ^a.inv.id), inc: [event_count: 1])
      Repo.update_all(from(i in Invocation, where: i.id == ^b.inv.id), inc: [log_bytes: 3])
      ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :raw_archive, :failures]])

      assert {:ok, :skipped} = RawStore.compact(a.inv.id, later())

      assert_receive {[:conveyor, :raw_archive, :failures], ^ref, %{count: 1},
                      %{reason: :mismatch}}

      assert raw_blobs() == 0
      assert RawStore.frames(Repo.get!(Invocation, a.inv.id)) == a.messages
      assert {:ok, :already_archived} = RawStore.compact(a.inv.id, later())

      # The log does not match: the events blob written before it is an orphan for the prune.
      assert {:ok, :skipped} = RawStore.compact(b.inv.id, later())
      assert raw_blobs() == 1
      assert Blobs.prune_orphans(DateTime.add(DateTime.utc_now(), 2, :hour)) == 1

      # Skipped builds no longer hold their partition back.
      dropped = RawStore.expire_partitions(Date.add(today, raw_days() + 1))
      assert "event_segments_#{Calendar.strftime(today, "%Y%m%d")}" in dropped
    end

    test "a build without log output gets no log blob", %{project: project} do
      a = build!(project)
      [a] = append!([{a, ["only", "events"], ""}], :blob)
      a = finish!(a)
      assert {:ok, :archived} = RawStore.compact(a.inv.id, later())
      inv = assert_reads!(a)
      assert inv.log_blob == nil and is_binary(inv.raw_blob)
    end

    @tag :capture_log
    test "a build without events is never archived", %{project: project} do
      a = finish!(build!(project))
      assert {:ok, :skipped} = RawStore.compact(a.inv.id, later())
    end

    test "a run compacts every due build whatever the page, breaking ties between equal finish times",
         %{project: project} do
      {a, b} = two_builds!(project, [:blob, :postgres])
      assert a.inv.finished_at == b.inv.finished_at

      assert %{archived: 2, skipped: 0, lost: 0, failed: 0, remaining?: false} =
               RawStore.compact_due(later(), page: 1)

      assert_reads!(a)
      assert_reads!(b)
    end

    test "builds that share objects are compacted with one ranged read per object, not per row",
         %{project: project} do
      adapter!(Counting)
      builds = for _ <- 1..6, do: build!(project)

      # Five group commits, every build in each: 5 objects, 6 × 5 event rows and as many log rows.
      builds =
        Enum.reduce(1..5, builds, fn g, builds ->
          append!(Enum.map(builds, &{&1, ["event #{g}"], "line #{g}\n"}), :blob)
        end)

      at = DateTime.utc_now()
      builds = Enum.map(builds, &finish!(&1, at))

      # One build alone: a ranged read per row (events and log are apart in each object).
      {{:ok, :archived}, alone} =
        Counting.count(fn -> RawStore.compact(hd(builds).inv.id, later()) end)

      assert alone.get_range == 10

      # The other five together: every object once.
      {result, together} = Counting.count(fn -> RawStore.compact_due(later()) end)
      assert %{archived: 5, failed: 0} = result
      assert together.get_range == 5
      Enum.each(builds, &assert_reads!/1)
    end

    test "a batch reads ahead no more than its budget: cut into smaller ones, or row by row", %{
      project: project
    } do
      adapter!(Counting)
      builds = for _ <- 1..3, do: build!(project)
      big = :crypto.strong_rand_bytes(2_000)
      builds = append!(Enum.map(builds, &{&1, [big], ""}), :blob)
      builds = Enum.map(builds, &finish!/1)

      # A budget of one build's bytes: three batches of one, a read each.
      {result, counts} =
        Counting.count(fn -> RawStore.compact_due(later(), prefetch_bytes: 2_100) end)

      assert %{archived: 3} = result
      assert counts.get_range == 3
      Enum.each(builds, &assert_reads!/1)

      # Less than one build's bytes: nothing is read ahead, the build is read row by row.
      [c] = append!([{build!(project), [big], "log\n"}], :blob)
      c = finish!(c)
      assert %{archived: 1} = RawStore.compact_due(later(), prefetch_bytes: 10)
      assert_reads!(c)
    end

    test "the job compacts what is due, snoozes when the deadline ends its run, and idles when off",
         %{project: project} do
      old = DateTime.add(DateTime.utc_now(), -3, :day)

      [a, b] =
        for _ <- 1..2 do
          [x] = append!([{build!(project, old), ["m"], "log\n"}], :blob)
          finish!(x, old)
        end

      previous = Application.get_env(:conveyor, ArchiveRaw)
      on_exit(fn -> Application.put_env(:conveyor, ArchiveRaw, previous || []) end)
      Application.put_env(:conveyor, ArchiveRaw, deadline_ms: 0, page: 1)
      assert {:snooze, 1} = perform_job(ArchiveRaw, %{})
      Application.put_env(:conveyor, ArchiveRaw, [])
      assert {:ok, %{archived: 1, remaining?: false}} = perform_job(ArchiveRaw, %{})
      assert_reads!(a)
      assert_reads!(b)

      # One build by id (the jobs enqueued per build before, or by hand): a job that names
      # another project finds nothing; one that carries the id alone still runs.
      [c] = append!([{build!(project, old), ["m"], ""}], :postgres)
      c = finish!(c, old)

      assert {:ok, :not_found} =
               perform_job(ArchiveRaw, %{id: c.inv.id, project_id: project.id + 1})

      assert {:ok, :archived} = perform_job(ArchiveRaw, %{id: c.inv.id, project_id: project.id})
      assert {:ok, :already_archived} = perform_job(ArchiveRaw, %{id: c.inv.id})

      compaction!(false)
      assert {:ok, :disabled} = perform_job(ArchiveRaw, %{})
      assert {:cancel, :disabled} = perform_job(ArchiveRaw, %{id: c.inv.id})
    end

    test "the hourly partition job keeps a day that holds an unarchived finished build", %{
      project: project
    } do
      old = DateTime.add(DateTime.utc_now(), -30, :day)
      a = build!(project, old)
      [a] = append!([{a, ["m"], "log\n"}], :postgres)
      a = finish!(a, old)
      name = "event_segments_#{Calendar.strftime(old, "%Y%m%d")}"

      assert {:ok, %{dropped: dropped}} = perform_job(PartitionMaintenance, %{})
      refute name in dropped
      assert_reads!(a)

      assert {:ok, :archived} = RawStore.compact(a.inv.id)
      assert {:ok, %{dropped: dropped}} = perform_job(PartitionMaintenance, %{})
      assert name in dropped
      assert_reads!(a)
    end

    test "the overdue gauge is published while compaction is on", %{project: project} do
      old = DateTime.add(DateTime.utc_now(), -3, :day)
      a = build!(project, old)
      [a] = append!([{a, ["m"], ""}], :postgres)
      finish!(a, old)
      ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :raw_archive, :overdue]])
      :persistent_term.erase({ConveyorWeb.Telemetry, :raw_archive_overdue})
      ConveyorWeb.Telemetry.measure_raw_archive()
      assert_receive {[:conveyor, :raw_archive, :overdue], ^ref, %{seconds: s}, _} when s > 86_400
      # Cached for a minute.
      ConveyorWeb.Telemetry.measure_raw_archive()
      assert_receive {[:conveyor, :raw_archive, :overdue], ^ref, %{seconds: ^s}, _}

      compaction!(false)
      ConveyorWeb.Telemetry.measure_raw_archive()
      refute_receive {[:conveyor, :raw_archive, :overdue], ^ref, _, _}
      :persistent_term.erase({ConveyorWeb.Telemetry, :raw_archive_overdue})
    end
  end

  describe "the sweep" do
    setup do
      compaction!(false)
      previous = Application.get_env(:conveyor, Conveyor.RawLog)
      Application.put_env(:conveyor, Conveyor.RawLog, Keyword.put(previous || [], :fsync, false))
      on_exit(fn -> Application.put_env(:conveyor, Conveyor.RawLog, previous) end)
    end

    # `n` objects of one shard, one per group, all past their date at the returned clock.
    defp expired_objects!(project, n, shard \\ "sweep") do
      a = build!(project)
      Enum.reduce(1..n, a, fn i, a -> hd(append!([{a, ["#{i}"], ""}], :blob, shard)) end)
      RawStore.expire_partitions(Date.add(Date.utc_today(), raw_days() + 1))
      DateTime.add(DateTime.utc_now(), raw_days() + 2, :day)
    end

    test "one run deletes everything that is due, page after page, faster than a node writes",
         %{project: project} do
      shard = "pace-#{System.unique_integer([:positive])}"
      clock = expired_objects!(project, 2_500, shard)
      {Disk, opts} = Blobs.adapter()
      [node_dir] = Path.wildcard(Path.join([opts[:dir], "rawlog", "*", shard]))
      on_exit(fn -> File.rm_rf(node_dir) end)
      assert length(File.ls!(node_dir)) == 2_500

      {micros, result} = :timer.tc(fn -> RawStore.expire_objects(clock, page: 1_000) end)
      assert %{deleted: 2_500, failed: 0, remaining?: false} = result
      assert %{objects: 0} = RawStore.expiry_backlog(clock)
      assert File.ls!(node_dir) == []
      # A node's bound is one object per shard per second; 153/s was the worst measured.
      assert 2_500 / (micros / 1_000_000) > 1_000
    end

    test "a run that reaches its deadline says so, and the job enqueues its own continuation",
         %{project: project} do
      clock = expired_objects!(project, 25)

      assert %{deleted: 10, remaining?: true} =
               RawStore.expire_objects(clock, page: 10, deadline_ms: 0)

      previous = Application.get_env(:conveyor, RawLogSweep)
      Application.put_env(:conveyor, RawLogSweep, deadline_ms: 0, page: 10)
      on_exit(fn -> Application.put_env(:conveyor, RawLogSweep, previous || []) end)
      as_of = DateTime.to_iso8601(clock)

      assert {:ok, %{deleted: 10, remaining?: true}} = perform_job(RawLogSweep, %{as_of: as_of})
      assert_enqueued(worker: RawLogSweep, args: %{as_of: as_of, continued: 1})

      assert {:ok, %{deleted: 5, remaining?: false}} =
               perform_job(RawLogSweep, %{as_of: as_of, continued: 1})

      refute_enqueued(worker: RawLogSweep, args: %{continued: 2})

      # On the wall clock nothing here is due.
      assert {:ok, %{deleted: 0, remaining?: false}} = perform_job(RawLogSweep, %{})
    end

    test "the backlog gauges are published", %{project: project} do
      expired_objects!(project, 2)
      ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :raw_log, :sweep_backlog]])
      :persistent_term.erase({ConveyorWeb.Telemetry, :raw_expiry_backlog})
      ConveyorWeb.Telemetry.measure_raw_expiry()

      assert_receive {[:conveyor, :raw_log, :sweep_backlog], ^ref,
                      %{objects: 0, overdue_seconds: 0}, _}

      # Cached for a minute.
      ConveyorWeb.Telemetry.measure_raw_expiry()
      assert_receive {[:conveyor, :raw_log, :sweep_backlog], ^ref, %{objects: 0}, _}
      :persistent_term.erase({ConveyorWeb.Telemetry, :raw_expiry_backlog})
    end
  end

  describe "through the commit pipeline" do
    setup do
      compaction!(true)
    end

    @fixtures ~w(clean_build_and_test cached_build_and_test build_failure test_failure flaky_test analysis_failure build_only_verbose)

    defp fixture_bytes(name),
      do: File.read!(Path.join([File.cwd!(), "test/fixtures/bep", name <> ".bep"]))

    defp pipeline_reads(id) do
      inv = Repo.get!(Invocation, id)
      assert :ok = Verify.check(id, inv.last_event_seq - 1)
      reads(inv)
    end

    for mode <- [:postgres, :blob] do
      test "#{mode} mode: every fixture is stored as it was sent and reads the same once archived",
           %{ctx: ctx} do
        raw_log_mode!(unquote(mode), flush_ms: 20)

        for name <- @fixtures do
          id = ingest_fixture!(name, ctx)
          before = pipeline_reads(id)
          # The download is the file Bazel would have written with --build_event_binary_file.
          assert before.bep == fixture_bytes(name)
          assert before.audit.problems == []

          assert {:ok, :archived} = RawStore.compact(id, later())
          assert pipeline_reads(id) == before
        end
      end
    end

    test "the two modes store the same bytes", %{ctx: ctx} do
      raw_log_mode!(:postgres, flush_ms: 20)
      reference = pipeline_reads(ingest_fixture!("clean_build_and_test", ctx))
      raw_log_mode!(:blob, flush_ms: 20)
      assert pipeline_reads(ingest_fixture!("clean_build_and_test", ctx)) == reference
    end

    test "downloads and the events tab of an archived build come from a one-shot store, byte for byte",
         %{conn: conn, ctx: ctx} do
      adapter!(OneShot)
      id = ingest_fixture!("build_only_verbose", ctx)
      log_resp = get(conn, ~p"/invocation/#{id}/download/log")
      log = response(log_resp, 200)
      events = response(get(build_conn(), ~p"/invocation/#{id}/download/events"), 200)
      assert events == fixture_bytes("build_only_verbose")

      assert {:ok, :archived} = RawStore.compact(id, later())
      RawStore.expire_partitions(Date.add(Date.utc_today(), raw_days() + 1))

      archived_log = get(build_conn(), ~p"/invocation/#{id}/download/log")
      assert response(archived_log, 200) == log

      assert get_resp_header(archived_log, "x-log-bytes") ==
               get_resp_header(log_resp, "x-log-bytes")

      assert get_resp_header(archived_log, "x-log-bytes") == [Integer.to_string(byte_size(log))]
      assert response(get(build_conn(), ~p"/invocation/#{id}/download/events"), 200) == events

      {:ok, view, _} = live(build_conn(), ~p"/invocation/#{id}/events")
      assert render(view) =~ "started"
    end

    test "dashboards read rows, never raw bytes: compaction changes no reported number", %{
      ctx: ctx
    } do
      alias Conveyor.Metrics.{Dashboard, Scope}
      ids = Enum.map(@fixtures, &ingest_fixture!(&1, ctx))
      scope = Scope.new("90d", ctx.project_id)
      dashboard = {Dashboard.exact_summary(scope), Dashboard.exact_series(scope)}
      for id <- ids, do: assert({:ok, :archived} = RawStore.compact(id, later()))
      assert {Dashboard.exact_summary(scope), Dashboard.exact_series(scope)} == dashboard
    end
  end

  describe "object reads" do
    test "a build's rows in one object are read with one ranged read", %{project: project} do
      adapter!(Counting)
      a = build!(project)
      b = build!(project)
      # One group: a's events, b's events, a's log, b's log, in one object; then two more.
      [a, b] = append!([{a, ["a1", "a2"], "a log\n"}, {b, ["b1"], "b log\n"}], :blob)
      [b, a] = append!([{b, ["b2"], ""}, {a, ["a3"], "more\n"}], :blob)
      [a, b] = append!([{a, ["a4"], ""}, {b, ["b3"], "end\n"}], :blob)
      a = finish!(a)
      finish!(b)

      # One ranged read per object that holds a piece of the build, never more.
      {frames, counts} = Counting.count(fn -> RawStore.frames(a.inv) end)
      assert frames == ["a1", "a2", "a3", "a4"]
      assert counts.get_range == 3
      {_, counts} = Counting.count(fn -> Enum.to_list(RawStore.log(a.inv).chunks) end)
      assert counts.get_range == 2
      {_, counts} = Counting.count(fn -> assert_reads!(a) end)
      assert counts.put_object == 0
    end
  end
end
