defmodule Conveyor.Ingest.WriterTest do
  use Conveyor.DataCase, async: false

  import Ecto.Query

  alias Conveyor.Ingest.{Batch, TagCounter, Writer, WriterPool}
  alias Conveyor.Invocations.{Invocation, Target}
  alias Conveyor.Projects
  alias Conveyor.Repo

  setup do
    project = Projects.ensure_default_project!()
    id = Conveyor.Bep.Replay.uuid()
    Repo.insert!(%Invocation{id: id, project_id: project.id, started_at: DateTime.utc_now()})
    %{id: id, project: project}
  end

  defp batch(id, project, first_seq, fun) do
    Batch.new(id, project.id, Date.utc_today(), first_seq, 0, 0) |> fun.()
  end

  @tag :capture_log
  test "commits a group of batches and notifies each submitter; fenced batches fail alone", %{
    id: id,
    project: project
  } do
    good =
      batch(id, project, 1, fn b ->
        b
        |> Batch.add_event(1, "started", "x")
        |> Batch.add_log(1, "hello\n")
        |> Batch.upsert_target({"//a", ""}, %{label: "//a", kind: "rule", status: "configured"})
        |> Batch.upsert_target({"//b", ""}, %{label: "//b", status: "success"})
        |> Batch.upsert_test({"//a", "", 1, 1, 1}, %{
          label: "//a",
          run: 1,
          shard: 1,
          attempt: 1,
          status: "PASSED"
        })
        |> Batch.add_action(%{seq: 1, mnemonic: "Genrule", success: false})
        |> Batch.add_named_set(%{set_id: "0", files: %{}})
        |> Batch.put_metrics(%{tool_logs: %{"a" => "b"}})
        |> Batch.set_invocation(%{command: "build", targets_configured: 1})
        |> Batch.count_tags(%{"k" => "v"})
      end)

    # Expects last_event_seq == 41, which is not the case: must be fenced without
    # affecting the good batch in the same group.
    fenced = batch(id, project, 42, &Batch.add_event(&1, 42, "progress", "y"))

    writer = WriterPool.for_invocation(id)
    Writer.submit(writer, good)
    Writer.submit(writer, fenced)

    good_ref = good.ref
    fenced_ref = fenced.ref
    assert_receive {:batch_committed, ^good_ref}, 2_000
    assert_receive {:batch_failed, ^fenced_ref, {:fenced, 41}}, 2_000

    inv = Repo.get!(Invocation, id)
    assert inv.last_event_seq == 1 and inv.command == "build" and inv.targets_configured == 1
    assert Repo.aggregate(from(t in Target, where: t.invocation_id == ^id), :count) == 2
    TagCounter.flush()
    assert [%{count: 1}] = Repo.all(from t in Conveyor.Invocations.TagKey, where: t.key == "k")

    # Partial upsert: a later batch touching only status must keep kind.
    later =
      batch(
        id,
        project,
        2,
        &Batch.upsert_target(&1, {"//a", ""}, %{label: "//a", status: "success"})
      )

    Writer.submit(writer, later)
    later_ref = later.ref
    assert_receive {:batch_committed, ^later_ref}, 2_000

    assert %{kind: "rule", status: "success"} =
             Repo.get_by!(Target, invocation_id: id, label: "//a")

    # Metrics upsert replaces only the given columns; tag counts increment.
    again =
      batch(id, project, 2, fn b ->
        b |> Batch.put_metrics(%{build_metrics: %{"x" => 1}}) |> Batch.count_tags(%{"k" => "v"})
      end)

    Writer.submit(writer, again)
    again_ref = again.ref
    assert_receive {:batch_committed, ^again_ref}, 2_000

    assert %{tool_logs: %{"a" => "b"}, build_metrics: %{"x" => 1}} =
             Conveyor.Invocations.metrics(id)

    TagCounter.flush()
    assert [%{count: 2}] = Repo.all(from t in Conveyor.Invocations.TagKey, where: t.key == "k")
  end

  @tag :capture_log
  test "reports database errors instead of crashing", %{id: id, project: project} do
    bad =
      batch(
        id,
        project,
        1,
        &Batch.add_action(&1, %{seq: 1, mnemonic: String.duplicate("x", 300)})
      )

    writer = WriterPool.for_invocation(id)
    Writer.submit(writer, bad)
    ref = bad.ref
    assert_receive {:batch_failed, ^ref, reason}, 2_000
    assert is_binary(reason)
    assert Process.alive?(GenServer.whereis(writer))
  end

  test "two batches of one invocation in a group merge into one row per table", %{
    id: id,
    project: project
  } do
    first =
      batch(id, project, 1, fn b ->
        b
        |> Batch.add_event(1, "started", "x")
        |> Batch.upsert_target({"//a", ""}, %{label: "//a", kind: "rule", status: "configured"})
        |> Batch.upsert_test({"//a", "", 1, 1, 1}, %{
          label: "//a",
          run: 1,
          shard: 1,
          attempt: 1,
          status: "PASSED"
        })
        |> Batch.put_metrics(%{tool_logs: %{"a" => "b"}})
        |> Batch.count_tags(%{"k" => "v"})
      end)

    second =
      batch(id, project, 2, fn b ->
        b
        |> Batch.add_event(2, "completed", "y")
        |> Batch.upsert_target({"//a", ""}, %{label: "//a", status: "success"})
        |> Batch.upsert_test({"//a", "", 1, 1, 1}, %{
          label: "//a",
          run: 1,
          shard: 1,
          attempt: 1,
          duration_ms: 7
        })
        |> Batch.put_metrics(%{build_metrics: %{"c" => 1}})
        |> Batch.count_tags(%{"k" => "v"})
      end)

    # Both are pending before the first flush, so they land in the same group commit.
    writer = WriterPool.for_invocation(id)
    Writer.submit(writer, first)
    Writer.submit(writer, second)
    first_ref = first.ref
    second_ref = second.ref
    assert_receive {:batch_committed, ^first_ref}, 2_000
    assert_receive {:batch_committed, ^second_ref}, 2_000

    assert Repo.get!(Invocation, id).last_event_seq == 2
    assert [%{kind: "rule", status: "success"}] = Conveyor.Invocations.targets(id)
    assert [%{status: "PASSED", duration_ms: 7}] = Conveyor.Invocations.test_results(id)

    assert %{tool_logs: %{"a" => "b"}, build_metrics: %{"c" => 1}} =
             Conveyor.Invocations.metrics(id)

    TagCounter.flush()
    assert [%{count: 2}] = Repo.all(from t in Conveyor.Invocations.TagKey, where: t.key == "k")
    assert Conveyor.Invocations.raw_frames(Repo.get!(Invocation, id)) == ["x", "y"]
  end

  @tag :capture_log
  test "a failed tag count after the group commit does not fail the batch", %{id: id} do
    # project_id nil violates NOT NULL on tag_keys only; the batch itself commits first.
    bad_tags =
      Batch.new(id, nil, Date.utc_today(), 1, 0, 0)
      |> Batch.add_event(1, "started", "x")
      |> Batch.count_tags(%{"k" => "v"})

    writer = WriterPool.for_invocation(id)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Writer.submit(writer, bad_tags)
        ref = bad_tags.ref
        assert_receive {:batch_committed, ^ref}, 2_000
        TagCounter.flush()
      end)

    assert log =~ "tag counts not updated"
    assert Repo.get!(Invocation, id).last_event_seq == 1
    assert Repo.all(from t in Conveyor.Invocations.TagKey, where: t.key == "k") == []
  end

  test "pool sharding is stable" do
    assert WriterPool.for_invocation("abc") == WriterPool.for_invocation("abc")
    assert WriterPool.shards() >= 1
    assert %Writer.Fenced{} = e = %Writer.Fenced{invocation_id: "i", expected: 3}
    assert Exception.message(e) =~ "fenced"
  end

  @tag :capture_log
  test "fenced updates of many invocations share one statement and a fenced one fails alone",
       %{project: project} do
    ids = for _ <- 1..5, do: Conveyor.Bep.Replay.uuid()

    for id <- ids,
        do:
          Repo.insert!(%Invocation{
            id: id,
            project_id: project.id,
            started_at: DateTime.utc_now()
          })

    finished = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # The same dirty columns on every batch: one UPDATE … FROM unnest for all of them, with
    # every column type the schema has (text, bigint, boolean, jsonb, timestamptz, text[]).
    good =
      for {id, i} <- Enum.with_index(ids, 1) do
        batch(id, project, 1, fn b ->
          b
          |> Batch.add_event(1, "started", "x")
          |> Batch.set_invocation(%{
            command: "build #{i}",
            targets_configured: i,
            stream_finished: rem(i, 2) == 0,
            tags: %{"n" => "#{i}"},
            finished_at: finished,
            patterns: ["//p#{i}", "//q"],
            abort_reason: nil
          })
        end)
      end

    # Expects last_event_seq 6 on a row that is at 0.
    fenced =
      batch(hd(ids), project, 7, fn b ->
        b
        |> Batch.add_event(7, "progress", "y")
        |> Batch.set_invocation(%{
          command: "late",
          targets_configured: 9,
          stream_finished: true,
          tags: %{},
          finished_at: finished,
          patterns: [],
          abort_reason: nil
        })
      end)

    # All batches go to one writer regardless of their shard so they share a flush.
    writer = WriterPool.for_invocation(hd(ids))
    Enum.each(good ++ [fenced], &Writer.submit(writer, &1))

    for b <- good do
      ref = b.ref
      assert_receive {:batch_committed, ^ref}, 5_000
    end

    fenced_ref = fenced.ref
    assert_receive {:batch_failed, ^fenced_ref, {:fenced, 6}}, 5_000

    for {id, i} <- Enum.with_index(ids, 1) do
      inv = Repo.get!(Invocation, id)
      assert inv.last_event_seq == 1
      assert inv.command == "build #{i}" and inv.targets_configured == i
      assert inv.stream_finished == (rem(i, 2) == 0)
      assert inv.tags == %{"n" => "#{i}"}
      assert inv.finished_at == finished
      assert inv.patterns == ["//p#{i}", "//q"]
      assert inv.abort_reason == nil
      assert inv.last_event_at != nil
    end
  end

  test "two units of one invocation in a flush are applied in order, in separate statements",
       %{id: id, project: project} do
    first = batch(id, project, 1, &Batch.add_event(&1, 1, "started", "a"))
    # Leaves a gap: only valid once the row is at 4, which it never is in this flush.
    resumed = batch(id, project, 5, &Batch.add_event(&1, 5, "progress", "b"))
    writer = WriterPool.for_invocation(id)
    Writer.submit(writer, first)
    Writer.submit(writer, resumed)
    first_ref = first.ref
    resumed_ref = resumed.ref
    assert_receive {:batch_committed, ^first_ref}, 5_000
    assert_receive {:batch_failed, ^resumed_ref, {:fenced, 4}}, 5_000
    assert Repo.get!(Invocation, id).last_event_seq == 1
  end
end
