defmodule Conveyor.ExecLog.SpawnInputsTest do
  @moduledoc """
  Deduplicated input lists (`spawn_inputs`), spawn retention and the store/prune race of
  docs/spec/SpawnInputs.tla: the upsert's `ON CONFLICT DO UPDATE` must take the row lock
  (pinned against a real second connection), pruning re-checks under it, dashboards keep
  their execution-log sums after the spawns are gone.
  """
  use Conveyor.DataCase, async: false

  import Ecto.Query

  alias Conveyor.{ExecLog, Projects, Repo}
  alias Conveyor.ExecLog.{Spawn, SpawnInput}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.Rollup

  @clean Path.join([File.cwd!(), "test/fixtures/execlog/clean.log.zst"])
  @changed Path.join([File.cwd!(), "test/fixtures/execlog/changed.log.zst"])

  setup do
    project = Projects.ensure_default_project!()
    %{project: project}
  end

  defp build(project, days_ago, tags \\ %{"branch" => "main"}) do
    at = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    Repo.insert!(%Invocation{
      id: Ecto.UUID.generate(),
      project_id: project.id,
      status: "succeeded",
      tags: tags,
      inserted_at: at,
      updated_at: at,
      started_at: at,
      finished_at: at
    })
  end

  defp parsed(path) do
    {:ok, p} = ExecLog.parse(File.read!(path))
    p
  end

  defp lists(project),
    do: Repo.aggregate(from(si in SpawnInput, where: si.project_id == ^project.id), :count)

  test "identical input lists are stored once per project and read back per spawn", %{
    project: project
  } do
    a = build(project, 2)
    b = build(project, 1)
    clean = parsed(@clean)
    distinct = clean.spawns |> Enum.map(& &1.inputs_digest) |> Enum.uniq() |> length()

    assert ExecLog.store!(a, clean) == 12
    assert lists(project) == distinct
    # The same log for a second build adds spawns, no lists.
    assert ExecLog.store!(b, clean) == 12
    assert lists(project) == distinct
    assert Repo.aggregate(Spawn, :count) == 24

    for s <- ExecLog.list(b) do
      inputs = ExecLog.inputs(s)
      assert length(inputs) == s.input_files

      assert Enum.all?(inputs, fn {path, digest} ->
               is_binary(path) and byte_size(digest) == 64
             end)
    end

    # A changed build adds only the lists that differ, and the diff reads both.
    c = build(project, 0)
    assert ExecLog.store!(c, parsed(@changed)) == 8
    assert lists(project) > distinct
    explained = ExecLog.explain(c)
    assert Enum.any?(explained.rows, &(&1.reason == :inputs_changed and &1.changed != []))

    # Another project storing the same log gets its own copies (the project boundary).
    {:ok, other} = Projects.create_project(%{slug: "spawn-inputs-other", name: "Other"})
    assert ExecLog.store!(build(other, 0), clean) == 12
    assert lists(other) == distinct
    assert lists(project) > distinct
  end

  test "spawn retention expires old builds' spawns and pruning removes orphan lists", %{
    project: project
  } do
    old = build(project, 40)
    recent = build(project, 3)
    assert ExecLog.store!(old, parsed(@clean)) == 12
    assert ExecLog.store!(recent, parsed(@changed)) == 8
    before = lists(project)

    # Default spawn retention is 30 days, bounded by build retention.
    assert ExecLog.retention_days(project) == 30

    {:ok, short} =
      Projects.put_storage(project, %{"retention_days" => "10", "spawn_retention_days" => "60"})

    assert ExecLog.retention_days(short) == 10

    {:ok, project} =
      Projects.put_storage(project, %{"retention_days" => "", "spawn_retention_days" => "30"})

    assert Projects.spawn_retention_days(project) == 30

    assert ExecLog.expire_before(project, ExecLog.retention_cutoff(project)) == 1
    assert Repo.get!(Invocation, old.id).exec_log_status == "expired"
    assert Repo.get!(Invocation, recent.id).exec_log_status == "parsed"
    assert ExecLog.list(old) == []
    assert length(ExecLog.list(recent)) == 8
    # Expiring again finds nothing.
    assert ExecLog.expire_before(project, ExecLog.retention_cutoff(project)) == 0

    # Lists only the old build used are orphans: kept within the grace period, then pruned.
    assert ExecLog.prune_orphan_inputs(DateTime.utc_now(), 3600) == 0
    assert lists(project) == before
    pruned = ExecLog.prune_orphan_inputs(DateTime.utc_now(), 0)
    assert pruned > 0
    assert lists(project) == before - pruned
    # Every remaining list is referenced, and the recent build still reads its inputs.
    for s <- ExecLog.list(recent), do: assert(length(ExecLog.inputs(s)) == s.input_files)
    assert ExecLog.prune_orphan_inputs(DateTime.utc_now(), 0) == 0
  end

  test "the nightly job expires spawns and prunes lists", %{project: project} do
    old = build(project, 40)
    assert ExecLog.store!(old, parsed(@clean)) == 12
    Repo.update_all(SpawnInput, set: [touched_at: DateTime.add(DateTime.utc_now(), -2, :hour)])

    assert {:ok, %{deleted: 0, pruned_inputs: pruned, projects: %{"default" => %{expired: 1}}}} =
             Oban.Testing.perform_job(Conveyor.Workers.BuildRetention, %{}, repo: Repo)

    assert pruned > 0
    assert lists(project) == 0
    assert Repo.get!(Invocation, old.id).exec_log_status == "expired"
  end

  test "rollups keep execution-log sums for hours past the spawn retention", %{project: project} do
    old = build(project, 40)
    assert ExecLog.store!(old, parsed(@clean)) == 12
    hour = old.started_at
    row = Rollup.roll!(project.id, hour)
    assert row.spawns == 12 and row.spawn_mnemonics != %{}

    assert ExecLog.expire_before(project, ExecLog.retention_cutoff(project)) == 1
    # Recomputing the hour (a build in it changed) must not zero the sums.
    again = Rollup.roll!(project.id, hour)
    assert again.spawns == 12 and again.spawn_mnemonics == row.spawn_mnemonics

    # An hour inside the retention window is recomputed from the rows as before.
    recent = build(project, 1)
    assert ExecLog.store!(recent, parsed(@changed)) == 8
    assert Rollup.roll!(project.id, recent.started_at).spawns == 8
    Repo.delete_all(from s in Spawn, where: s.invocation_id == ^recent.id)
    assert Rollup.roll!(project.id, recent.started_at).spawns == 0
  end

  # Two builds sharing lists in a different spawn order would lock them in a different
  # order and deadlock (found by an 8-writer load test); every store sorts by digest.
  test "a store upserts its lists once each, in digest order" do
    spawns = [
      %{inputs_digest: "b", inputs_list: "B"},
      %{inputs_digest: "a", inputs_list: "A"},
      %{inputs_digest: "b", inputs_list: "B"},
      %{inputs_digest: "c", inputs_list: "C"}
    ]

    now = DateTime.utc_now()
    rows = ExecLog.input_rows(7, spawns, now)
    assert Enum.map(rows, & &1.digest) == ["a", "b", "c"]
    assert Enum.map(rows, & &1.blob) == ["A", "B", "C"]
    assert Enum.all?(rows, &(&1.project_id == 7 and &1.touched_at == now))
    # The same lists in another order lock in the same order.
    assert ExecLog.input_rows(7, Enum.reverse(spawns), now) == rows
  end

  # docs/spec/SpawnInputs.tla, LockOnUpsert: a store's upsert must hold the list's row
  # lock until it commits, or pruning could delete the list between its re-check and its
  # delete while the store commits a reference. Pinned against Postgres itself with two
  # connections outside the test sandbox: DO UPDATE blocks a FOR UPDATE, DO NOTHING would not.
  test "the list upsert takes the row lock (DO UPDATE), which DO NOTHING would not", %{
    project: project
  } do
    config = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database])
    {:ok, a} = Postgrex.start_link(config)
    {:ok, b} = Postgrex.start_link(config)
    digest = String.duplicate("f", 64)

    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(config)
      Postgrex.query!(c, "DELETE FROM spawn_inputs WHERE digest = $1", [digest])
      GenServer.stop(c)
    end)

    Postgrex.query!(
      a,
      "INSERT INTO spawn_inputs (project_id, digest, blob, touched_at) VALUES ($1, $2, $3, now())",
      [project.id, digest, <<>>]
    )

    upsert =
      "INSERT INTO spawn_inputs (project_id, digest, blob, touched_at) VALUES ($1, $2, $3, now())"

    lock = "SELECT 1 FROM spawn_inputs WHERE project_id = $1 AND digest = $2 FOR UPDATE NOWAIT"

    # What store!/2 does: the lock is held, so a prune's FOR UPDATE must wait.
    Postgrex.transaction(a, fn conn ->
      Postgrex.query!(
        conn,
        upsert <> " ON CONFLICT (project_id, digest) DO UPDATE SET touched_at = now()",
        [project.id, digest, <<>>]
      )

      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               Postgrex.query(b, lock, [project.id, digest])
    end)

    # The alternative the model rejects: DO NOTHING leaves the row unlocked.
    Postgrex.transaction(a, fn conn ->
      Postgrex.query!(conn, upsert <> " ON CONFLICT (project_id, digest) DO NOTHING", [
        project.id,
        digest,
        <<>>
      ])

      assert {:ok, %{num_rows: 1}} = Postgrex.query(b, lock, [project.id, digest])
    end)

    GenServer.stop(a)
    GenServer.stop(b)
  end
end
