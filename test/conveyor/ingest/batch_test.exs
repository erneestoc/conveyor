defmodule Conveyor.Ingest.BatchTest do
  use ExUnit.Case, async: true

  alias Conveyor.Bep.Fixture
  alias Conveyor.Ingest.Batch
  alias Conveyor.Invocations

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

  test "event segments use the BEP dictionary and frames without one still decode" do
    frames = ["abc", "defg"]
    with_dict = Invocations.compress_bep(frames)
    plain = Invocations.compress(frames)
    assert {:ok, %{dictID: 1}} = :zstd.get_frame_header(with_dict)
    assert {:ok, %{dictID: 0}} = :zstd.get_frame_header(plain)
    assert Invocations.decompress(with_dict) == "abcdefg"
    assert Invocations.decompress(plain) == "abcdefg"

    # A real event stream: the dictionary earns its keep.
    raw = File.read!(fixture_path("clean_build_and_test")) |> Fixture.frames()
    assert byte_size(Invocations.compress_bep(raw)) < byte_size(Invocations.compress(raw)) * 0.8
    assert Invocations.decompress(Invocations.compress_bep(raw)) == IO.iodata_to_binary(raw)
  end

  defp fixture_path(name), do: Path.join([File.cwd!(), "test/fixtures/bep", name <> ".bep"])

  test "event and log segments round-trip through compression with offsets" do
    batch =
      Batch.new(@id, 1, ~D[2026-09-18], 3, 100, 7)
      |> Batch.add_event(3, "started", "abc")
      |> Batch.add_event(4, "progress", "defg")
      |> Batch.add_log(4, "line1\nline2\n")
      |> Batch.add_log(5, "")
      |> Batch.add_log(5, "tail")

    row = Batch.event_segment_row(batch)

    assert %{first_seq: 3, last_seq: 4, count: 2, kinds: ["started", "progress"], byte_size: 7} =
             row

    assert row.payload |> Invocations.decompress() |> Fixture.frames() == ["abc", "defg"]

    log = Batch.log_segment_row(batch)

    assert %{
             first_seq: 4,
             last_seq: 5,
             byte_offset: 100,
             line_offset: 7,
             byte_size: 16,
             line_count: 2
           } = log

    assert Invocations.decompress(log.data) == "line1\nline2\ntail"
    assert Batch.event_count(batch) == 2
  end

  test "upserts merge attributes per key and tags are counted" do
    batch =
      Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0)
      |> Batch.upsert_target({"//a", ""}, %{label: "//a", kind: "rule"})
      |> Batch.upsert_target({"//a", ""}, %{status: "success"})
      |> Batch.upsert_test({"//a", "", 1, 1, 1}, %{status: "PASSED"})
      |> Batch.add_action(%{seq: 1})
      |> Batch.add_named_set(%{set_id: "0"})
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

    assert %{first_seq: 1, last_seq: 2, count: 2, kinds: ["started", "progress"]} =
             Batch.event_segment_row(m)

    assert m
           |> Batch.event_segment_row()
           |> Map.fetch!(:payload)
           |> Invocations.decompress()
           |> Fixture.frames() == ["abc", "de"]

    assert %{byte_offset: 0, line_offset: 0, byte_size: 8, line_count: 2} =
             log = Batch.log_segment_row(m)

    assert Invocations.decompress(log.data) == "one\ntwo\n"

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
  end
end
