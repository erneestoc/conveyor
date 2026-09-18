defmodule Conveyor.Ingest.WriterTest do
  use Conveyor.DataCase, async: false

  import Ecto.Query

  alias Conveyor.Ingest.{Batch, Writer, WriterPool}
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

  test "pool sharding is stable" do
    assert WriterPool.for_invocation("abc") == WriterPool.for_invocation("abc")
    assert WriterPool.shards() >= 1
    assert %Writer.Fenced{} = e = %Writer.Fenced{invocation_id: "i", expected: 3}
    assert Exception.message(e) =~ "fenced"
  end
end
