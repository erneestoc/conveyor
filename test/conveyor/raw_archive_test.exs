defmodule Conveyor.RawArchiveTest do
  use ConveyorWeb.LiveCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  import Ecto.Query

  alias Conveyor.{Blobs, Invocations, RawArchive, Repo}
  alias Conveyor.Ingest.Verify
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Storage.Partitions
  alias Conveyor.Workers.{ArchiveRaw, PartitionMaintenance}

  setup do
    prev = Application.get_env(:conveyor, RawArchive)
    Application.put_env(:conveyor, RawArchive, enabled: true, after_hours: 24)
    on_exit(fn -> Application.put_env(:conveyor, RawArchive, prev) end)
    %{ctx: context(), later: DateTime.add(DateTime.utc_now(), 2, :day)}
  end

  defp snapshot(inv) do
    %{
      frames: Invocations.raw_frames(inv),
      events: Invocations.events(inv),
      page: Invocations.events_page(inv, 2, 7),
      log: Invocations.log(inv),
      raw: inv |> Invocations.stream_raw() |> Enum.to_list() |> IO.iodata_to_binary()
    }
  end

  defp sent(inv), do: inv.last_event_seq - 1

  test "archiving keeps every read byte-identical and the oracle green", %{ctx: ctx, later: later} do
    id = ingest_fixture!("build_only_verbose", ctx)
    # Fixture builds carry the recording's event times; make this one finish now.
    Repo.update_all(from(i in Invocation, where: i.id == ^id),
      set: [finished_at: DateTime.utc_now()]
    )

    before = Repo.get!(Invocation, id)
    assert before.raw_status == "segments" and before.log_bytes > 0
    expected = snapshot(before)
    assert :ok = Verify.check(id, sent(before))

    assert {:ok, :not_due} = RawArchive.archive(id)
    assert id in RawArchive.all_candidates(later)
    assert RawArchive.overdue_seconds(later) > 0
    assert RawArchive.holds_unarchived?(Invocations.day(before))

    assert {:ok, :archived} = RawArchive.archive(id, later)
    inv = Repo.get!(Invocation, id)
    assert inv.raw_status == "archived" and inv.raw_archived_at
    assert Invocations.archived?(inv)
    # The archive changes no reported value: rollups key their staleness on updated_at.
    assert inv.updated_at == before.updated_at

    # Read from the blobs, not the segments: remove the segments to prove it.
    Repo.delete_all(from s in "event_segments", where: s.invocation_id == type(^id, :binary_id))
    Repo.delete_all(from s in "log_segments", where: s.invocation_id == type(^id, :binary_id))
    assert snapshot(inv) == expected
    assert :ok = Verify.check(id, sent(inv))
    assert [%{byte_offset: 0, byte_size: bytes}] = Invocations.log_segments(inv)
    assert bytes == byte_size(expected.log)

    # The events object is a compressed --build_event_binary_file with the BEP dictionary.
    {:ok, stored} = Blobs.read(inv.project_id, inv.raw_blob)
    assert {:ok, %{dictID: 1}} = :zstd.get_frame_header(stored)
    assert Invocations.decompress(stored) == expected.raw
    assert {:ok, log} = Blobs.read(inv.project_id, inv.log_blob)
    assert Invocations.decompress(log) == expected.log

    refute id in RawArchive.all_candidates(later)
    refute RawArchive.holds_unarchived?(Invocations.day(inv))
    assert {:ok, :already_archived} = RawArchive.archive(id, later)
    assert {:ok, :not_found} = RawArchive.archive(Ecto.UUID.generate(), later)
  end

  test "a run sees every due build, not one page", %{ctx: ctx, later: later} do
    ids =
      for f <- ~w(clean_build_and_test build_failure test_failure), do: ingest_fixture!(f, ctx)

    # Same finish time for two of them: the cursor breaks ties by id.
    at = DateTime.utc_now()
    Repo.update_all(from(i in Invocation, where: i.id in ^ids), set: [finished_at: at])

    found = RawArchive.all_candidates(later, 2)
    assert Enum.sort(found) == Enum.sort(found |> Enum.uniq())
    assert Enum.all?(ids, &(&1 in found))
    assert length(RawArchive.candidates(later, 2)) == 2
  end

  test "the loser of two archivers keeps the winner's blobs; retention frees them", %{
    ctx: ctx,
    later: later
  } do
    id = ingest_fixture!("clean_build_and_test", ctx)
    stale = Repo.get!(Invocation, id)

    assert {:ok, :archived} = RawArchive.archive(id, later)
    inv = Repo.get!(Invocation, id)

    # A second node loaded the row before the first archived it: same content, same
    # digests; its conditional update finds nothing and its discard leaves them alone.
    assert {:ok, :lost} = RawArchive.archive(stale, later)
    assert Blobs.exists?(inv.project_id, inv.raw_blob)
    assert Blobs.exists?(inv.project_id, inv.log_blob)

    # Orphan pruning keeps referenced raw blobs ...
    age_blobs(inv)
    Blobs.prune_orphans()
    assert Blobs.exists?(inv.project_id, inv.raw_blob)

    # ... and removes them once retention deleted the build.
    Repo.delete_all(from i in Invocation, where: i.id == ^id)
    assert Blobs.prune_orphans() >= 2
    refute Blobs.exists?(inv.project_id, inv.raw_blob)
    refute Blobs.exists?(inv.project_id, inv.log_blob)
  end

  test "a build deleted while it was being archived leaves no blob behind", %{
    ctx: ctx,
    later: later
  } do
    id = ingest_fixture!("build_failure", ctx)
    stale = Repo.get!(Invocation, id)
    Repo.delete_all(from i in Invocation, where: i.id == ^id)

    assert {:ok, :lost} = RawArchive.archive(stale, later)
    assert Repo.all(from b in Blobs.Blob, where: b.source == "raw") == []
  end

  @tag :capture_log
  test "segments that do not match the row are skipped, not archived", %{ctx: ctx, later: later} do
    id = ingest_fixture!("test_failure", ctx)
    Repo.update_all(from(i in Invocation, where: i.id == ^id), inc: [event_count: 1])

    assert {:ok, :skipped} = RawArchive.archive(id, later)
    inv = Repo.get!(Invocation, id)
    assert inv.raw_status == "skipped" and inv.raw_blob == nil
    assert Repo.all(from b in Blobs.Blob, where: b.source == "raw") == []
    # A skipped build no longer holds its partition back.
    refute RawArchive.holds_unarchived?(Invocations.day(inv))

    id2 = ingest_fixture!("flaky_test", ctx)
    Repo.update_all(from(i in Invocation, where: i.id == ^id2), inc: [log_bytes: 3])
    assert {:ok, :skipped} = RawArchive.archive(id2, later)
  end

  test "a build without log output gets no log blob", %{ctx: ctx, later: later} do
    id = ingest_fixture!("cached_build_and_test", ctx)
    Repo.update_all(from(i in Invocation, where: i.id == ^id), set: [log_bytes: 0])
    Repo.delete_all(from s in "log_segments", where: s.invocation_id == type(^id, :binary_id))

    assert {:ok, :archived} = RawArchive.archive(id, later)
    inv = Repo.get!(Invocation, id)

    assert inv.log_blob == nil and Invocations.log(inv) == "" and
             Invocations.log_segments(inv) == []

    assert :ok = Verify.check(id, sent(inv))
  end

  test "a pin refuses a row whose bytes are gone", %{
    ctx: ctx,
    later: later
  } do
    id = ingest_fixture!("analysis_failure", ctx)
    inv = Repo.get!(Invocation, id)
    {:ok, blob} = Blobs.put(inv.project_id, "unrelated #{System.unique_integer()}")

    # Pinning checks the bytes under the row lock (docs/spec/Blobs.tla).
    {adapter, opts} = Blobs.adapter()
    adapter.delete(blob.digest, Keyword.put(opts, :project_prefix, blob.prefix))

    assert {:ok, {:error, :blob_gone}} =
             Repo.transaction(fn -> Blobs.pin(inv.project_id, blob.digest) end)

    assert {:ok, :archived} = RawArchive.archive(id, later)
  end

  test "the worker schedules due builds, archives by id and idles when disabled", %{ctx: ctx} do
    id = ingest_fixture!("clean_build_and_test", ctx)
    old = DateTime.add(DateTime.utc_now(), -3, :day)

    Repo.update_all(from(i in Invocation, where: i.id == ^id),
      set: [inserted_at: old, finished_at: old, updated_at: old]
    )

    # The build's partition is the day it was created.
    Partitions.ensure_day(DateTime.to_date(old))
    move_segments(id, DateTime.to_date(old))

    assert {:ok, %{enqueued: n}} = perform_job(ArchiveRaw, %{})
    assert n >= 1
    assert_enqueued(worker: ArchiveRaw, args: %{id: id})
    assert {:ok, :archived} = perform_job(ArchiveRaw, %{id: id})

    Application.put_env(:conveyor, RawArchive, enabled: false)
    assert {:ok, :disabled} = perform_job(ArchiveRaw, %{})
    assert {:cancel, :disabled} = perform_job(ArchiveRaw, %{id: id})
  end

  test "the partition drop keeps a day that holds an unarchived finished build", %{ctx: ctx} do
    id = ingest_fixture!("clean_build_and_test", ctx)
    day = Date.add(Date.utc_today(), -30)
    at = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    Partitions.ensure_day(day)

    Repo.update_all(from(i in Invocation, where: i.id == ^id),
      set: [inserted_at: at, finished_at: at, updated_at: at]
    )

    move_segments(id, day)
    name = Partitions.partition_name("event_segments", day)

    assert {:ok, %{dropped: dropped}} = perform_job(PartitionMaintenance, %{})
    refute name in dropped
    assert name in Partitions.partition_names("event_segments")

    assert {:ok, :archived} = RawArchive.archive(id)
    assert {:ok, %{dropped: dropped}} = perform_job(PartitionMaintenance, %{})
    assert name in dropped
    assert :ok = Verify.check(id, sent(Repo.get!(Invocation, id)))
  end

  test "the overdue gauge is published while the archive is on", %{ctx: ctx} do
    ingest_fixture!("clean_build_and_test", ctx)
    ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :raw_archive, :overdue]])
    :persistent_term.erase({ConveyorWeb.Telemetry, :raw_archive_overdue})
    ConveyorWeb.Telemetry.measure_raw_archive()
    assert_receive {[:conveyor, :raw_archive, :overdue], ^ref, %{seconds: s}, _} when s >= 0
    # Cached for a minute.
    ConveyorWeb.Telemetry.measure_raw_archive()
    assert_receive {[:conveyor, :raw_archive, :overdue], ^ref, %{seconds: ^s}, _}

    Application.put_env(:conveyor, RawArchive, enabled: false)
    ConveyorWeb.Telemetry.measure_raw_archive()
    refute_receive {[:conveyor, :raw_archive, :overdue], ^ref, _, _}
  end

  defp age_blobs(inv) do
    old = DateTime.add(DateTime.utc_now(), -2, :hour)

    Repo.update_all(from(b in Blobs.Blob, where: b.project_id == ^inv.project_id),
      set: [inserted_at: old]
    )
  end

  # Segment rows live in the partition of the build's creation day.
  defp move_segments(id, day) do
    for table <- ~w(event_segments log_segments) do
      Repo.query!("UPDATE #{table} SET day = $1 WHERE invocation_id = $2", [
        day,
        Ecto.UUID.dump!(id)
      ])
    end
  end
end
