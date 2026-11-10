defmodule Conveyor.Ingest.WriterTest do
  @moduledoc """
  The commit pipeline against Postgres, through its interface: batches are submitted,
  outcomes are received, and the rows and objects are what the outcomes say. What the
  pipeline decides (when to commit, what to do after a failed attempt) is tested without
  a database in `writer/flush_test.exs` and `writer/policy_test.exs`; here each decision
  is carried out once for real.
  """
  use Conveyor.DataCase, async: false

  import Ecto.Query

  alias Conveyor.Ingest.{Batch, TagCounter, Writer, WriterPool}
  alias Conveyor.Ingest.Writer.Config
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

  # A shard of its own with the node's configuration and the given changes.
  defp shard!(overrides) do
    shard = "test-#{System.os_time(:microsecond)}"
    config = struct!(Config.from_env(), overrides)
    start_supervised!({Writer, shard: shard, config: config}, id: shard)
    shard
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
    assert Process.alive?(Writer.whereis(writer))
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
    assert Conveyor.RawStore.frames(Repo.get!(Invocation, id)) == ["x", "y"]
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
  end

  @tag :capture_log
  test "every column type travels through the fenced update; a fenced unit fails alone",
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

  @tag :capture_log
  test "the fence is judged before any child row is written", %{id: id, project: project} do
    # Stale (the row is at 0, the batch expects 41) and unwritable (the mnemonic is too
    # long for its column): the verdict is the fence, reached before the insert that would
    # have failed, and the batch next to it commits.
    stale =
      batch(id, project, 42, fn b ->
        b
        |> Batch.add_event(42, "progress", "y")
        |> Batch.add_action(%{seq: 42, mnemonic: String.duplicate("x", 300)})
      end)

    other = Conveyor.Bep.Replay.uuid()
    Repo.insert!(%Invocation{id: other, project_id: project.id, started_at: DateTime.utc_now()})
    good = batch(other, project, 1, &Batch.add_event(&1, 1, "started", "x"))

    writer = WriterPool.for_invocation(id)
    Writer.submit(writer, stale)
    Writer.submit(writer, good)
    stale_ref = stale.ref
    good_ref = good.ref
    assert_receive {:batch_failed, ^stale_ref, {:fenced, 41}}, 2_000
    assert_receive {:batch_committed, ^good_ref}, 2_000
  end

  # Every batch is in the writer's mailbox before it looks at the first: one flush.
  defp submit_together(writer, batches) do
    pid = Writer.whereis(writer)
    :ok = :sys.suspend(pid)
    Enum.each(batches, &Writer.submit(writer, &1))
    :ok = :sys.resume(pid)
  end

  defp invocation!(project) do
    id = Conveyor.Bep.Replay.uuid()
    Repo.insert!(%Invocation{id: id, project_id: project.id, started_at: DateTime.utc_now()})
    id
  end

  defp objects, do: Repo.aggregate(from(o in "raw_log_objects"), :count)

  # Makes the database answer an `actions` row by its mnemonic, for the rest of the test's
  # transaction: "refuse" as if it had no connection to spare (SQLSTATE 53300), "deadlock"
  # as the victim of a deadlock (40P01), "cancel" as a statement that ran into its timeout
  # (57014).
  defp refuse_work! do
    Repo.query!("""
    CREATE FUNCTION conveyor_test_refuse() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.mnemonic = 'refuse' THEN
        RAISE EXCEPTION 'injected' USING ERRCODE = '53300';
      ELSIF NEW.mnemonic = 'deadlock' THEN
        RAISE EXCEPTION 'injected' USING ERRCODE = '40P01';
      ELSIF NEW.mnemonic = 'cancel' THEN
        RAISE EXCEPTION 'injected' USING ERRCODE = '57014';
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!("""
    CREATE TRIGGER conveyor_test_refuse BEFORE INSERT ON actions
    FOR EACH ROW EXECUTE FUNCTION conveyor_test_refuse()
    """)
  end

  @tag :capture_log
  test "a group is stored as one object, whatever its attempts: fenced, refused, committed",
       %{project: project} do
    writer = shard!(blob?: true)
    before = objects()
    good = for _ <- 1..6, do: invocation!(project)
    committed = for id <- good, do: batch(id, project, 1, &Batch.add_event(&1, 1, "started", id))

    # Expects last_event_seq 6 on a row that is at 0.
    fenced = batch(invocation!(project), project, 7, &Batch.add_event(&1, 7, "progress", "y"))

    refused =
      batch(invocation!(project), project, 1, fn b ->
        b
        |> Batch.add_event(1, "started", "z")
        |> Batch.add_action(%{seq: 1, mnemonic: String.duplicate("x", 300)})
      end)

    submit_together(writer, [fenced, refused | committed])

    fenced_ref = fenced.ref
    refused_ref = refused.ref
    assert_receive {:batch_failed, ^fenced_ref, {:fenced, 6}}, 5_000
    assert_receive {:batch_failed, ^refused_ref, reason}, 5_000
    assert reason =~ "value too long"

    for b <- committed do
      ref = b.ref
      assert_receive {:batch_committed, ^ref}, 5_000
    end

    # The retry without the fenced unit and the halves that isolated the refused one all
    # point into the object stored for the first attempt.
    assert objects() == before + 1

    for id <- good do
      inv = Repo.get!(Invocation, id)
      assert inv.last_event_seq == 1
      assert Conveyor.RawStore.frames(inv) == [id]
    end

    assert Repo.get!(Invocation, fenced.invocation_id).last_event_seq == 0
    assert Repo.get!(Invocation, refused.invocation_id).last_event_seq == 0
  end

  @tag :capture_log
  test "while the database refuses work the group waits, then fails whole: nothing is committed alone",
       %{project: project} do
    writer = shard!(blob?: true)
    refuse_work!()
    before = objects()
    ids = for _ <- 1..5, do: invocation!(project)

    batches =
      for {id, i} <- Enum.with_index(ids) do
        batch(id, project, 1, fn b ->
          b
          |> Batch.add_event(1, "started", "x")
          |> Batch.add_action(%{seq: 1, mnemonic: if(i == 2, do: "refuse", else: "Genrule")})
        end)
      end

    submit_together(writer, batches)

    for b <- batches do
      ref = b.ref
      assert_receive {:batch_failed, ^ref, reason}, 5_000
      assert reason =~ "too_many_connections"
    end

    for id <- ids, do: assert(Repo.get!(Invocation, id).last_event_seq == 0)
    assert objects() == before + 1
  end

  @tag :capture_log
  test "a statement that ran into its timeout is the database being slow, not a bad row: the group is not halved",
       %{project: project} do
    writer = shard!(blob?: true)
    refuse_work!()
    ids = for _ <- 1..4, do: invocation!(project)

    batches =
      for {id, i} <- Enum.with_index(ids) do
        batch(id, project, 1, fn b ->
          b
          |> Batch.add_event(1, "started", "x")
          |> Batch.add_action(%{seq: 1, mnemonic: if(i == 1, do: "cancel", else: "Genrule")})
        end)
      end

    submit_together(writer, batches)

    # Halved, the three other builds would have committed in transactions of their own.
    for b <- batches do
      ref = b.ref
      assert_receive {:batch_failed, ^ref, reason}, 5_000
      assert reason =~ "query_canceled"
    end

    for id <- ids, do: assert(Repo.get!(Invocation, id).last_event_seq == 0)
  end

  @tag :capture_log
  test "a group that keeps deadlocking is retried, then halved: the unit in the way fails alone",
       %{project: project} do
    refuse_work!()
    ids = for _ <- 1..4, do: invocation!(project)

    [a, b, c, d] =
      for {id, i} <- Enum.with_index(ids) do
        batch(id, project, 1, fn b ->
          b
          |> Batch.add_event(1, "started", "x")
          |> Batch.add_action(%{seq: 1, mnemonic: if(i == 1, do: "deadlock", else: "Genrule")})
        end)
      end

    submit_together(WriterPool.for_invocation(hd(ids)), [a, b, c, d])

    b_ref = b.ref
    assert_receive {:batch_failed, ^b_ref, reason}, 5_000
    assert reason =~ "deadlock_detected"

    for batch <- [a, c, d] do
      ref = batch.ref
      assert_receive {:batch_committed, ^ref}, 5_000
    end
  end

  @tag :capture_log
  test "while the object store refuses the object the group waits, then fails whole; every try is the same object",
       %{project: project} do
    # A store outage: every put fails while the switch is on.
    previous = Application.get_env(:conveyor, Conveyor.Blobs)
    root = Path.join(System.tmp_dir!(), "conveyor-no-store-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.put_env(:conveyor, Conveyor.Blobs, previous)
      Application.delete_env(:conveyor, :flaky_object_puts)
      File.rm_rf(root)
    end)

    Application.put_env(:conveyor, Conveyor.Blobs,
      adapter: Conveyor.Blobs.Flaky,
      opts: [dir: root]
    )

    Application.put_env(:conveyor, :flaky_object_puts, true)

    test_pid = self()
    handler = "writer-test-puts-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:conveyor, :raw_log, :put_failed],
      fn _, _, _, _ -> send(test_pid, :put_failed) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    writer = shard!(blob?: true)
    before = objects()
    ids = for _ <- 1..3, do: invocation!(project)
    batches = for id <- ids, do: batch(id, project, 1, &Batch.add_event(&1, 1, "started", "x"))
    submit_together(writer, batches)

    for b <- batches do
      ref = b.ref
      assert_receive {:batch_failed, ^ref, reason}, 5_000
      assert reason =~ "raw log put"
    end

    # The first try and one per retry delay, all under the one key registered for the group.
    for _ <- 0..length(Config.from_env().retry_delays), do: assert_received(:put_failed)
    refute_received :put_failed
    assert objects() == before + 1
    for id <- ids, do: assert(Repo.get!(Invocation, id).last_event_seq == 0)
  end

  @tag :capture_log
  test "a batch past its deadline is expired: never attempted, nothing written, its followers with it",
       %{id: id, project: project} do
    # A shard whose batches are due the moment they arrive.
    writer = shard!(blob?: true, deadline_ms: 0)
    before = objects()

    batches = [
      batch(id, project, 1, &Batch.add_event(&1, 1, "started", "a")),
      batch(id, project, 2, &Batch.add_event(&1, 2, "progress", "b")),
      batch(invocation!(project), project, 1, &Batch.add_event(&1, 1, "started", "c"))
    ]

    Enum.each(batches, &Writer.submit(writer, &1))

    for b <- batches do
      ref = b.ref
      assert_receive {:batch_failed, ^ref, :expired}, 2_000
    end

    assert Repo.get!(Invocation, id).last_event_seq == 0
    assert objects() == before
  end

  # Returns once the clock the gauge reads has moved.
  defp tick(from \\ System.monotonic_time(:millisecond)) do
    if System.monotonic_time(:millisecond) == from, do: tick(from), else: :ok
  end

  test "pressure: what a shard was handed and has not answered, and the age of the oldest",
       %{id: id, project: project} do
    start_supervised!({Writer, shard: 779})
    idle = %{batches: 0, bytes: 0, oldest_ms: 0}
    assert Writer.pressure(779) == idle
    assert Writer.pressure(:no_such_shard) == idle

    # The shard is busy (suspended): what it is handed waits in its mailbox, and shows.
    :ok = :sys.suspend(Writer.whereis(779))
    first = batch(id, project, 1, &Batch.add_event(&1, 1, "started", "12345"))
    second = batch(id, project, 2, &Batch.add_log(&1, 2, "678\n"))
    {:ok, _} = Writer.submit(779, first)
    tick()
    {:ok, _} = Writer.submit(779, second)

    assert %{batches: 2, bytes: 9, oldest_ms: age} = Writer.pressure(779)
    assert age >= 1
    tick()
    assert Writer.pressure(779).oldest_ms > age

    :ok = :sys.resume(Writer.whereis(779))
    first_ref = first.ref
    second_ref = second.ref
    assert_receive {:batch_committed, ^first_ref}, 2_000
    assert_receive {:batch_committed, ^second_ref}, 2_000
    assert Writer.pressure(779) == idle

    # A restarted shard starts from zero whatever its predecessor was holding.
    :ok = :sys.suspend(Writer.whereis(779))
    {:ok, old} = Writer.submit(779, batch(id, project, 3, &Batch.add_event(&1, 3, "x", "y")))
    assert Writer.pressure(779).batches == 1
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    assert is_pid(await_restart(779, old))
    assert Writer.pressure(779) == idle
  end

  defp await_restart(shard, old) do
    case Writer.whereis(shard) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        receive do
        after
          5 -> await_restart(shard, old)
        end
    end
  end

  test "the pool's pressure is the sum of its shards and the age of the oldest batch on any" do
    assert WriterPool.pressure() == %{batches: 0, bytes: 0, oldest_ms: 0}

    # Before a pool has started on the node (the telemetry poller runs earlier) there is
    # nothing to read, and reading it is not an error.
    count = WriterPool.shards()
    :persistent_term.erase({WriterPool, :shards})
    on_exit(fn -> :persistent_term.put({WriterPool, :shards}, count) end)
    assert WriterPool.shards() == 0
    assert WriterPool.pressure() == %{batches: 0, bytes: 0, oldest_ms: 0}
    assert ConveyorWeb.Telemetry.measure_writer_backlog() == :ok
    assert WriterPool.for_invocation("abc") == 0
    :persistent_term.put({WriterPool, :shards}, count)
    shard = WriterPool.for_invocation("abc")
    assert shard in 0..(WriterPool.shards() - 1)
  end

  test "a batch that ends a stream is committed at once, and takes what waited with it", %{
    id: id,
    project: project
  } do
    # A hold far longer than the test: only the end of the stream can commit these.
    writer = shard!(hold_ms: 60_000)
    plain = batch(id, project, 1, &Batch.add_event(&1, 1, "started", "a"))
    {:ok, pid} = Writer.submit(writer, plain)
    # (A hold that elapses after its group was committed is ignored.)
    send(pid, {:timeout, make_ref(), :flush})

    final =
      batch(
        id,
        project,
        2,
        &(&1 |> Batch.add_event(2, "finished", "b") |> Map.put(:finalize, true))
      )

    Writer.submit(writer, final)
    plain_ref = plain.ref
    final_ref = final.ref
    assert_receive {:batch_committed, ^plain_ref}, 2_000
    assert_receive {:batch_committed, ^final_ref}, 2_000
    assert Repo.get!(Invocation, id).last_event_seq == 2
  end

  test "blob mode: enough waiting bytes commit a group before its hold", %{
    id: id,
    project: project
  } do
    writer = shard!(blob?: true, hold_ms: 60_000, max_bytes: 3)
    before = objects()
    small = batch(id, project, 1, &Batch.add_event(&1, 1, "started", "ab"))
    enough = batch(id, project, 2, &Batch.add_event(&1, 2, "progress", "c"))
    Writer.submit(writer, small)
    Writer.submit(writer, enough)
    small_ref = small.ref
    enough_ref = enough.ref
    assert_receive {:batch_committed, ^small_ref}, 2_000
    assert_receive {:batch_committed, ^enough_ref}, 2_000
    assert objects() == before + 1
    assert Conveyor.RawStore.frames(Repo.get!(Invocation, id)) == ["ab", "c"]
  end

  test "two units of one invocation in a group are applied in order: the one the row does not continue is fenced",
       %{id: id, project: project} do
    first = batch(id, project, 1, &Batch.add_event(&1, 1, "started", "a"))
    # Leaves a gap: only valid once the row is at 4, which it never is in this flush.
    resumed = batch(id, project, 5, &Batch.add_event(&1, 5, "progress", "b"))
    submit_together(WriterPool.for_invocation(id), [first, resumed])
    first_ref = first.ref
    resumed_ref = resumed.ref
    assert_receive {:batch_committed, ^first_ref}, 5_000
    assert_receive {:batch_failed, ^resumed_ref, {:fenced, 4}}, 5_000
    assert Repo.get!(Invocation, id).last_event_seq == 1
  end
end
