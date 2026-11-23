defmodule Conveyor.Ingest.BatchTest do
  use ExUnit.Case, async: true

  alias Conveyor.Bep.Fixture
  alias Conveyor.Ingest.Batch
  alias Conveyor.RawStore.Codec

  @id "11111111-1111-4111-8111-111111111111"

  test "empty batches produce no segment rows" do
    batch = Batch.new(@id, 1, ~D[2026-09-18], 5, 0, 0)
    assert Batch.empty?(batch)
    assert Batch.event_segment_row(batch) == nil
    assert Batch.log_segment_row(batch) == nil
    assert batch.last_seq == 4

    marked = Batch.add_marker(batch, 5)
    refute Batch.empty?(marked)
    assert marked.last_seq == 5
  end

  test "event and log segments round-trip through compression with offsets" do
    batch =
      Batch.new(@id, 1, ~D[2026-09-18], 3, 100, 7)
      |> Batch.add_event(3, "started", "abc")
      |> Batch.add_event(4, "progress", "defg")
      |> Batch.add_log(4, "line1\nline2\n")
      |> Batch.add_log(5, "")
      |> Batch.add_log(5, "tail")

    row = Batch.event_segment_row(batch)

    assert %{first_seq: 3, last_seq: 4, count: 2, byte_size: 7} = row
    # Nothing reads the kinds of a segment: the column keeps its default.
    refute Map.has_key?(row, :kinds)

    assert row.payload |> Codec.decompress() |> Fixture.frames() == ["abc", "defg"]

    log = Batch.log_segment_row(batch)

    assert %{
             first_seq: 4,
             last_seq: 5,
             byte_offset: 100,
             line_offset: 7,
             byte_size: 16,
             line_count: 2
           } = log

    assert Codec.decompress(log.data) == "line1\nline2\ntail"
    assert Batch.event_count(batch) == 2
  end

  test "upserts merge attributes per key and tags are counted" do
    batch =
      Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0)
      |> Batch.upsert_target({"//a", ""}, %{label: "//a", kind: "rule"})
      |> Batch.upsert_target({"//a", ""}, %{status: "success"})
      |> Batch.upsert_test({"//a", "", 1, 1, 1}, %{status: "PASSED"})
      |> Batch.add_action(%{seq: 1})
      |> Batch.put_metrics(%{tool_logs: %{}})
      |> Batch.put_metrics(%{build_metrics: %{}})
      |> Batch.set_invocation(%{status: "failed"})
      |> Batch.count_tags(%{"a" => "1"})
      |> Batch.count_tags(%{"a" => "1", "b" => "2"})
      |> Batch.add_waiter({:ack, self()}, 1)

    assert batch.targets == %{{"//a", ""} => %{label: "//a", kind: "rule", status: "success"}}
    assert batch.metrics == %{tool_logs: %{}, build_metrics: %{}}
    assert batch.tag_keys == %{{"a", "1"} => 2, {"b", "2"} => 1}
    assert [{{:ack, _}, 1}] = batch.waiters
    refute Batch.empty?(batch)
  end

  test "merge joins two contiguous batches into one equivalent batch" do
    a =
      Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0)
      |> Batch.add_event(1, "started", "abc")
      |> Batch.add_log(1, "one\n")
      |> Batch.upsert_target({"//a", ""}, %{label: "//a", kind: "rule", status: "configured"})
      |> Batch.add_action(%{seq: 1, mnemonic: "A"})
      |> Batch.put_metrics(%{tool_logs: %{"a" => "b"}})
      |> Batch.set_invocation(%{command: "build", targets_configured: 1})
      |> Batch.count_tags(%{"k" => "v"})
      |> Batch.add_waiter({:ack, self()}, 1)

    b =
      Batch.new(@id, 1, ~D[2026-09-18], 2, 4, 1)
      |> Batch.add_event(2, "progress", "de")
      |> Batch.add_marker(3)
      |> Batch.add_log(2, "two\n")
      |> Batch.upsert_target({"//a", ""}, %{label: "//a", status: "success"})
      |> Batch.upsert_test({"//a", "", 1, 1, 1}, %{label: "//a", status: "PASSED"})
      |> Batch.add_action(%{seq: 2, mnemonic: "B"})
      |> Batch.put_metrics(%{build_metrics: %{"x" => 1}})
      |> Batch.set_invocation(%{targets_configured: 2, status: "succeeded"})
      |> Batch.count_tags(%{"k" => "v", "j" => "w"})
      |> Batch.add_waiter({:ack, self()}, 2)
      |> Map.put(:finalize, true)

    assert Batch.contiguous?(a, b)
    refute Batch.contiguous?(b, a)
    m = Batch.merge(a, b)

    assert %{ref: ref, first_seq: 1, last_seq: 3, finalize: true, event_bytes: 5} = m
    assert ref == a.ref
    assert Batch.event_count(m) == 2

    assert %{first_seq: 1, last_seq: 2, count: 2} = Batch.event_segment_row(m)

    assert m
           |> Batch.event_segment_row()
           |> Map.fetch!(:payload)
           |> Codec.decompress()
           |> Fixture.frames() == ["abc", "de"]

    assert %{byte_offset: 0, line_offset: 0, byte_size: 8, line_count: 2} =
             log = Batch.log_segment_row(m)

    assert Codec.decompress(log.data) == "one\ntwo\n"

    assert m.targets == %{{"//a", ""} => %{label: "//a", kind: "rule", status: "success"}}
    assert map_size(m.tests) == 1
    assert Enum.map(m.actions, & &1.seq) == [2, 1]
    assert m.metrics == %{tool_logs: %{"a" => "b"}, build_metrics: %{"x" => 1}}
    assert m.invocation == %{command: "build", targets_configured: 2, status: "succeeded"}
    assert m.tag_keys == %{{"k", "v"} => 2, {"j", "w"} => 1}
    assert length(m.waiters) == 2

    assert_raise ArgumentError, fn -> Batch.merge(b, a) end
  end

  test "coalesce merges an invocation's contiguous batches and keeps the rest apart" do
    other = "22222222-2222-4222-8222-222222222222"
    a1 = Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0) |> Batch.add_event(1, "started", "a")
    o1 = Batch.new(other, 1, ~D[2026-09-18], 1, 0, 0) |> Batch.add_event(1, "started", "o")
    a2 = Batch.new(@id, 1, ~D[2026-09-18], 2, 1, 0) |> Batch.add_event(2, "progress", "b")
    # A resumed stream after a takeover: not contiguous with what this flush already holds.
    a3 = Batch.new(@id, 1, ~D[2026-09-18], 9, 2, 0) |> Batch.add_event(9, "finished", "c")
    o2 = Batch.new(other, 1, ~D[2026-09-18], 2, 1, 0) |> Batch.add_event(2, "finished", "p")

    units = Batch.coalesce([a1, o1, a2, a3, o2])

    assert Enum.map(units, &{&1.invocation_id, &1.first_seq, &1.last_seq}) == [
             {@id, 1, 2},
             {@id, 9, 9},
             {other, 1, 2}
           ]

    assert Batch.coalesce([]) == []
    assert Batch.coalesce([a1]) == [a1]

    # Each unit is named by its invocation and its position among that invocation's units,
    # and lists the batches merged into it.
    assert [{{@id, 0}, _, [r1, r2]}, {{@id, 1}, _, [r3]}, {{^other, 0}, _, [r4, r5]}] =
             Batch.units([a1, o1, a2, a3, o2])

    assert [r1, r2, r3, r4, r5] == [a1.ref, a2.ref, a3.ref, o1.ref, o2.ref]

    # A second batch starting at the same sequence (a restarted worker) is its own unit.
    skipping = fn first, base, steps ->
      Enum.reduce(
        steps,
        Batch.skipped_base(Batch.new(@id, 1, ~D[2026-09-18], first, 0, 0), base),
        fn
          {:event, seq}, b -> Batch.add_event(b, seq, "progress", "p")
          {:skip, seq}, b -> Batch.add_skipped(b, seq)
        end
      )
    end

    # Skipped frames are counted; a segment row says how many lie below its last event.
    s1 = skipping.(1, 0, skip: 1, event: 2, skip: 3, skip: 4)
    assert Batch.absorbed(s1) == 4 and Batch.event_count(s1) == 1 and not Batch.empty?(s1)
    assert %{first_seq: 2, last_seq: 2, count: 1, skipped_total: 1} = Batch.event_segment_row(s1)
    # Only skipped frames: the batch acknowledges them and writes no segment.
    s2 = skipping.(5, 3, skip: 5, skip: 6)
    assert s2.last_seq == 6 and Batch.event_segment_row(s2) == nil and not Batch.empty?(s2)
    s3 = skipping.(7, 5, skip: 7, event: 8)
    assert %{first_seq: 8, skipped_total: 6} = Batch.event_segment_row(s3)
    # Merged, the tail of skipped frames carries across batches without events.
    m12 = Batch.merge(s1, s2)
    assert {m12.skipped, m12.skipped_tail, m12.skipped_base} == {5, 4, 0}
    assert %{skipped_total: 1} = Batch.event_segment_row(m12)
    m = Batch.merge(m12, s3)
    assert %{first_seq: 2, last_seq: 8, count: 2, skipped_total: 6} = Batch.event_segment_row(m)

    again = Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0) |> Batch.add_event(1, "started", "a")
    assert [{{@id, 0}, _, _}, {{@id, 1}, _, _}] = Batch.units([a1, again])
  end
end
