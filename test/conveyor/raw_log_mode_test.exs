defmodule Conveyor.RawLogModeTest do
  use Conveyor.IngestCase, async: false

  alias Conveyor.{Invocations, Projects, RawArchive, RawLog}
  alias Conveyor.Bep.Replay
  alias Conveyor.Ingest.Verify
  alias Conveyor.Invocations.{EventSegment, Invocation, LogSegment}
  import Ecto.Query

  setup %{project: project} do
    {:ok, _key, key} = Projects.create_api_key(project, %{name: "rawlog"})
    previous = Application.get_env(:conveyor, RawLog)
    on_exit(fn -> Application.put_env(:conveyor, RawLog, previous) end)
    %{key: key}
  end

  defp ingest!(port, key, fixture, opts \\ []) do
    {:ok, %{invocation_id: id, sent: sent}} =
      Replay.run(fixture(fixture), [port: port, api_key: key] ++ opts)

    :ok = await_worker_exit(id)
    assert :ok = Conveyor.Ingest.Verify.check(id, sent - 1)
    Invocations.get!(id)
  end

  test "blob mode stores bytes in objects and reads them back identically", %{
    grpc_port: port,
    key: key
  } do
    Application.put_env(:conveyor, RawLog, mode: :postgres, flush_ms: 20)
    reference = ingest!(port, key, "clean_build_and_test")

    Application.put_env(:conveyor, RawLog, mode: :blob, flush_ms: 20)
    assert RawLog.blob_mode?()
    inv = ingest!(port, key, "clean_build_and_test")

    rows = Repo.all(from(s in EventSegment, where: s.invocation_id == ^inv.id))

    assert rows != [] and
             Enum.all?(
               rows,
               &(is_nil(&1.payload) and is_binary(&1.object_key) and &1.object_length > 0)
             )

    logs = Repo.all(from(s in LogSegment, where: s.invocation_id == ^inv.id))
    assert logs != [] and Enum.all?(logs, &is_nil(&1.data))

    assert Invocations.events(inv) |> Enum.map(& &1.id) ==
             Invocations.events(reference) |> Enum.map(& &1.id)

    assert Invocations.log(inv) == Invocations.log(reference)
    assert length(Invocations.raw_frames(inv)) == length(Invocations.raw_frames(reference))

    # The object is the only copy: once swept, the build's raw data is gone.
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) >= 1
    assert_raise RuntimeError, ~r/raw log/, fn -> Invocations.log(inv) end
  end

  defp count_ranges(fun) do
    counter = :counters.new(2, [])
    handler = "ranges-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:conveyor, :raw_log, :get_range],
      fn _, %{count: c, bytes: b}, _, _ ->
        :counters.add(counter, 1, c)
        :counters.add(counter, 2, b)
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, :counters.get(counter, 1), :counters.get(counter, 2)}
  end

  test "a multi-row build is read with one range per object, byte-identical", %{
    grpc_port: port,
    key: key
  } do
    Application.put_env(:conveyor, RawLog, mode: :postgres, flush_ms: 20)
    reference = ingest!(port, key, "clean_build_and_test")

    # Paced events make the build many batches and rows. The writer merges a build's
    # contiguous batches of one group commit into one row, so each row of a build is in
    # its own object: the read is one range per object, never one per row of an object.
    Application.put_env(:conveyor, RawLog, mode: :blob, flush_ms: 20)
    inv = ingest!(port, key, "clean_build_and_test", delay_ms: 25)

    events_q = from(s in EventSegment, where: s.invocation_id == ^inv.id)
    event_rows = Repo.aggregate(events_q, :count)
    objects = Repo.all(from(s in events_q, select: s.object_key, distinct: true))
    assert event_rows > 2 and length(objects) <= event_rows

    {events, event_ranges, event_bytes} = count_ranges(fn -> Invocations.events(inv) end)
    assert Enum.map(events, & &1.id) == Invocations.events(reference) |> Enum.map(& &1.id)
    assert event_ranges == length(objects)
    assert event_bytes == Repo.aggregate(events_q, :sum, :object_length)

    {log, log_ranges, _} = count_ranges(fn -> Invocations.log(inv) end)
    assert log == Invocations.log(reference)

    assert log_ranges <=
             Repo.aggregate(from(s in LogSegment, where: s.invocation_id == ^inv.id), :count)
  end

  test "the archive compacts a build whose rows are byte ranges", %{grpc_port: port, key: key} do
    prev = Application.get_env(:conveyor, RawArchive)
    on_exit(fn -> Application.put_env(:conveyor, RawArchive, prev) end)
    Application.put_env(:conveyor, RawArchive, enabled: true, after_hours: 24)

    Application.put_env(:conveyor, RawLog, mode: :blob, flush_ms: 20)
    inv = ingest!(port, key, "clean_build_and_test", delay_ms: 25)
    sent = inv.last_event_seq - 1
    # Fixture builds carry the recording's event times; make this one finish now.
    Repo.update_all(from(i in Invocation, where: i.id == ^inv.id),
      set: [finished_at: DateTime.utc_now()]
    )

    inv = Invocations.get!(inv.id)
    assert inv.raw_status == "segments"
    events = Invocations.events(inv)
    log = Invocations.log(inv)
    assert log != ""

    later = DateTime.add(DateTime.utc_now(), 2, :day)
    assert {:ok, :archived} = RawArchive.archive(inv.id, later)
    archived = Invocations.get!(inv.id)
    assert Invocations.archived?(archived)
    assert :ok = Verify.check(inv.id, sent)
    assert Invocations.events(archived) == events
    assert Invocations.log(archived) == log

    # The archived copy stands on its own: the raw-log objects can go.
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) >= 1
    assert Invocations.events(archived) == events
    assert Invocations.log(archived) == log
  end

  test "a writer shard in blob mode flushes by pending bytes before its hold" do
    # A long hold and a one-byte threshold: the first batch flushes at once. The build
    # does not exist, so the commit fences, which is the proof that the flush happened.
    Application.put_env(:conveyor, RawLog, mode: :blob, flush_ms: 60_000, flush_bytes: 1)
    pid = start_supervised!({Conveyor.Ingest.Writer, shard: :bytes_test})

    batch =
      Conveyor.Ingest.Batch.new(Ecto.UUID.generate(), 1, Date.utc_today(), 1, 0, 0)
      |> Conveyor.Ingest.Batch.add_event(1, "started", "not a build event")

    Conveyor.Ingest.Writer.submit(pid, batch)
    assert_receive {:batch_failed, ref, {:fenced, _}}, 5_000
    assert ref == batch.ref
  end

  test "fetch_rows! splits coalesced ranges, breaks on gaps and keys, and keeps inline rows" do
    key = RawLog.new_key(0)
    other = RawLog.new_key(1)
    assert :ok = RawLog.put(key, Enum.map(0..9, &String.duplicate(<<&1>>, 100)))
    assert :ok = RawLog.put(other, "zzzz")

    row = fn k, o, l -> %{data: nil, object_key: k, object_offset: o, object_length: l} end

    rows = [
      row.(key, 0, 100),
      row.(key, 100, 100),
      %{data: "inline", object_key: nil, object_offset: nil, object_length: nil},
      row.(key, 300, 100),
      row.(key, 400, 50),
      row.(key, 800, 100),
      row.(other, 0, 4),
      row.(other, 2, 2)
    ]

    {filled, ranges, _} = count_ranges(fn -> RawLog.fetch_rows!(rows, :data) end)

    assert Enum.map(filled, & &1.data) == [
             String.duplicate(<<0>>, 100),
             String.duplicate(<<1>>, 100),
             "inline",
             String.duplicate(<<3>>, 100),
             String.duplicate(<<4>>, 50),
             String.duplicate(<<8>>, 100),
             "zzzz",
             "zz"
           ]

    # [0,200), [300,450), [800,900) (a 350-byte gap is coalesced), "other" twice (overlap).
    assert ranges == 4

    assert_raise RuntimeError, ~r/raw log/, fn ->
      RawLog.fetch_rows!([row.(key, 900, 200)], :data)
    end
  end
end
