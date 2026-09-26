defmodule Conveyor.RawArchiveIdentityTest do
  @moduledoc """
  HANDOFF §7 item 7: every read of a build is byte-identical before and after the raw
  archive, the downloads stream from the store, and the chaos cases of
  `docs/spec/Archive.tla` (a crash between put and reference, two archivers at once, a
  store outage) end with the build archived exactly once and the oracle green.
  """
  use ConveyorWeb.LiveCase, async: false

  import Ecto.Query

  alias Conveyor.{Blobs, Invocations, RawArchive, Repo}
  alias Conveyor.Ingest.Verify
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.{Dashboard, Scope}

  @fixtures ~w(clean_build_and_test cached_build_and_test build_failure test_failure flaky_test analysis_failure build_only_verbose)

  setup do
    prev = Application.get_env(:conveyor, RawArchive)
    Application.put_env(:conveyor, RawArchive, enabled: true, after_hours: 24)
    on_exit(fn -> Application.put_env(:conveyor, RawArchive, prev) end)
    %{ctx: context(), later: DateTime.add(DateTime.utc_now(), 2, :day)}
  end

  defp reads(inv) do
    {_, total} = Invocations.events_page(inv, 1, 5)

    %{
      frames: Invocations.raw_frames(inv),
      events: Invocations.events(inv),
      pages: for(p <- 1..max(div(total + 4, 5), 1), do: Invocations.events_page(inv, p, 5)),
      log: Invocations.log(inv),
      log_chunks: inv |> Invocations.stream_log() |> Enum.to_list() |> IO.iodata_to_binary(),
      raw: inv |> Invocations.stream_raw() |> Enum.to_list() |> IO.iodata_to_binary()
    }
  end

  defp drop_segments(id) do
    for table <- ~w(event_segments log_segments),
        do: Repo.query!("DELETE FROM #{table} WHERE invocation_id = $1", [Ecto.UUID.dump!(id)])
  end

  defp sent(id), do: Repo.get!(Invocation, id).last_event_seq - 1

  test "every fixture reads the same from the blobs as from the segments", %{
    ctx: ctx,
    later: later
  } do
    project_id = ctx.project_id
    ids = Enum.map(@fixtures, &ingest_fixture!(&1, ctx))
    before = Map.new(ids, &{&1, reads(Repo.get!(Invocation, &1))})
    scope = Scope.new("90d", project_id)
    dashboard = {Dashboard.exact_summary(scope), Dashboard.exact_series(scope)}

    for id <- ids, do: assert({:ok, :archived} = RawArchive.archive(id, later))

    for id <- ids do
      drop_segments(id)
      inv = Repo.get!(Invocation, id)
      assert Invocations.archived?(inv)
      assert reads(inv) == before[id], "reads differ for #{id}"

      assert before[id].raw ==
               IO.iodata_to_binary(
                 Enum.map(
                   before[id].frames,
                   &[Conveyor.Bep.Fixture.encode_varint(byte_size(&1)), &1]
                 )
               )

      assert :ok = Verify.check(id, sent(id))
    end

    # Dashboards read rows, never raw data, and the archive does not touch updated_at.
    assert {Dashboard.exact_summary(scope), Dashboard.exact_series(scope)} == dashboard
  end

  test "downloads of an archived build stream from a one-shot store", %{
    conn: conn,
    ctx: ctx,
    later: later
  } do
    prev = Application.get_env(:conveyor, Blobs)
    on_exit(fn -> Application.put_env(:conveyor, Blobs, prev) end)
    Application.put_env(:conveyor, Blobs, adapter: Blobs.OneShot, opts: [dir: prev[:dir]])

    id = ingest_fixture!("build_only_verbose", ctx)
    log_resp = get(conn, ~p"/invocation/#{id}/download/log")
    events_resp = get(build_conn(), ~p"/invocation/#{id}/download/events")
    log = response(log_resp, 200)
    events = response(events_resp, 200)

    assert {:ok, :archived} = RawArchive.archive(id, later)
    drop_segments(id)

    archived_log = get(build_conn(), ~p"/invocation/#{id}/download/log")
    assert response(archived_log, 200) == log

    assert get_resp_header(archived_log, "x-log-bytes") ==
             get_resp_header(log_resp, "x-log-bytes")

    assert get_resp_header(archived_log, "x-log-bytes") == [Integer.to_string(byte_size(log))]

    archived_events = get(build_conn(), ~p"/invocation/#{id}/download/events")
    assert response(archived_events, 200) == events

    # The Events tab and the log tab render from the blobs.
    {:ok, view, _} = live(build_conn(), ~p"/invocation/#{id}/events")
    assert render(view) =~ "started"
  end

  test "a crash between put and reference leaves an orphan the prune removes", %{
    ctx: ctx,
    later: later
  } do
    id = ingest_fixture!("test_failure", ctx)
    expected = reads(Repo.get!(Invocation, id))

    # Archive, then undo the reference: exactly the state after a node died between the
    # put and the conditional update.
    assert {:ok, :archived} = RawArchive.archive(id, later)
    inv = Repo.get!(Invocation, id)

    Repo.update_all(from(i in Invocation, where: i.id == ^id),
      set: [raw_status: "segments", raw_blob: nil, log_blob: nil, raw_archived_at: nil]
    )

    old = DateTime.add(DateTime.utc_now(), -2, :hour)
    Repo.update_all(from(b in Blobs.Blob, where: b.source == "raw"), set: [inserted_at: old])
    assert Blobs.prune_orphans() >= 2
    refute Blobs.exists?(inv.project_id, inv.raw_blob)

    # The next run archives again, to the same digests.
    assert {:ok, :archived} = RawArchive.archive(id, later)
    again = Repo.get!(Invocation, id)
    assert {again.raw_blob, again.log_blob} == {inv.raw_blob, inv.log_blob}
    drop_segments(id)
    assert reads(again) == expected
  end

  test "two archivers at once: one wins, the build reads the same", %{ctx: ctx, later: later} do
    id = ingest_fixture!("flaky_test", ctx)
    expected = reads(Repo.get!(Invocation, id))
    stale = Repo.get!(Invocation, id)

    outcomes =
      [stale, stale, id]
      |> Enum.map(fn arg -> Task.async(fn -> RawArchive.archive(arg, later) end) end)
      |> Task.await_many(30_000)
      |> Enum.sort()

    assert Enum.count(outcomes, &(&1 == {:ok, :archived})) == 1

    assert Enum.all?(
             outcomes,
             &(&1 in [{:ok, :archived}, {:ok, :lost}, {:ok, :already_archived}])
           )

    drop_segments(id)
    assert reads(Repo.get!(Invocation, id)) == expected
    assert :ok = Verify.check(id, sent(id))
  end

  @tag :capture_log
  test "a store outage fails the run and a later one archives", %{ctx: ctx, later: later} do
    prev = Application.get_env(:conveyor, Blobs)

    on_exit(fn ->
      Application.put_env(:conveyor, Blobs, prev)
      Application.delete_env(:conveyor, :flaky_blob_puts)
    end)

    Application.put_env(:conveyor, Blobs, adapter: Blobs.Flaky, opts: [dir: prev[:dir]])
    id = ingest_fixture!("cached_build_and_test", ctx)
    ref = :telemetry_test.attach_event_handlers(self(), [[:conveyor, :raw_archive, :failures]])

    Application.put_env(:conveyor, :flaky_blob_puts, true)
    assert {:error, :store_unavailable} = RawArchive.archive(id, later)
    assert_receive {[:conveyor, :raw_archive, :failures], ^ref, %{count: 1}, %{reason: :error}}
    assert Repo.get!(Invocation, id).raw_status == "segments"
    assert RawArchive.holds_unarchived?(Invocations.day(Repo.get!(Invocation, id)))

    Application.put_env(:conveyor, :flaky_blob_puts, false)
    assert {:ok, :archived} = RawArchive.archive(id, later)
    assert :ok = Verify.check(id, sent(id))
  end
end
