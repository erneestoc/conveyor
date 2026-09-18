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
end
