# Concurrency load test for deduplicated input lists: W writers store real execution logs
# into fresh builds for D seconds while one task expires random builds' spawns and another
# prunes orphan lists with no grace period, the worst case docs/spec/SpawnInputs.tla
# models. Afterwards every spawn must still reference an existing list.
#   MIX_ENV=prod DATABASE_URL=... mix run --no-start bench/spawn_load.exs LOGDIR WRITERS SECONDS
Logger.configure(level: :warning)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)
{:ok, _} = Conveyor.Repo.start_link(pool_size: 20)
import Ecto.Query
alias Conveyor.{ExecLog, Repo}
alias Conveyor.ExecLog.{Spawn, SpawnInput}
alias Conveyor.Invocations.Invocation

[dir, writers, seconds] = System.argv()
writers = String.to_integer(writers)
seconds = String.to_integer(seconds)
project = Conveyor.Projects.ensure_default_project!()
Repo.query!("TRUNCATE spawns, spawn_inputs")
Repo.delete_all(from i in Invocation, where: i.project_id == ^project.id)

logs =
  dir
  |> File.ls!()
  |> Enum.sort()
  |> Enum.map(fn f ->
    {:ok, p} = ExecLog.parse(File.read!(Path.join(dir, f)))
    p
  end)

deadline = System.monotonic_time(:millisecond) + seconds * 1000
stores = :counters.new(1, [])
expired = :counters.new(1, [])
pruned = :counters.new(1, [])

new_build = fn ->
  at = DateTime.utc_now()

  Repo.insert!(%Invocation{
    id: Ecto.UUID.generate(),
    project_id: project.id,
    status: "succeeded",
    tags: %{"branch" => "main"},
    inserted_at: at,
    updated_at: at,
    started_at: at,
    finished_at: at
  })
end

writer = fn n ->
  Stream.cycle(logs)
  |> Enum.reduce_while(n, fn parsed, i ->
    if System.monotonic_time(:millisecond) > deadline do
      {:halt, i}
    else
      ExecLog.store!(new_build.(), parsed)
      :counters.add(stores, 1, 1)
      {:cont, i + 1}
    end
  end)
end

expirer = fn ->
  Stream.repeatedly(fn -> :ok end)
  |> Enum.reduce_while(0, fn _, i ->
    if System.monotonic_time(:millisecond) > deadline do
      {:halt, i}
    else
      ids =
        Repo.all(
          from i in Invocation,
            where: i.exec_log_status == "parsed",
            order_by: fragment("random()"),
            limit: 2,
            select: i.id
        )

      for id <- ids do
        Repo.transaction(fn ->
          Repo.delete_all(from s in Spawn, where: s.invocation_id == ^id)

          Repo.update_all(from(i in Invocation, where: i.id == ^id),
            set: [exec_log_status: "expired"]
          )
        end)
      end

      :counters.add(expired, 1, length(ids))
      Process.sleep(200)
      {:cont, i + 1}
    end
  end)
end

pruner = fn ->
  Stream.repeatedly(fn -> :ok end)
  |> Enum.reduce_while(0, fn _, i ->
    if System.monotonic_time(:millisecond) > deadline do
      {:halt, i}
    else
      :counters.add(pruned, 1, ExecLog.prune_orphan_inputs(DateTime.utc_now(), 0))
      {:cont, i + 1}
    end
  end)
end

tasks = for w <- 1..writers, do: Task.async(fn -> writer.(w) end)
tasks = tasks ++ [Task.async(expirer), Task.async(pruner)]
Task.await_many(tasks, :infinity)

# The invariant: no spawn without its list (anti-join through the invocation's project).
dangling =
  Repo.one(
    from s in Spawn,
      join: i in Invocation,
      on: i.id == s.invocation_id,
      left_join: si in SpawnInput,
      on: si.project_id == i.project_id and si.digest == s.inputs_digest,
      where: is_nil(si.digest),
      select: count(s.id)
  )

orphans =
  Repo.one(
    from si in SpawnInput,
      as: :list,
      where:
        not exists(
          from s in Spawn,
            join: i in Invocation,
            on: i.id == s.invocation_id,
            where:
              s.inputs_digest == parent_as(:list).digest and
                i.project_id == parent_as(:list).project_id,
            select: 1
        ),
      select: count()
  )

spawns = Repo.aggregate(Spawn, :count)
lists = Repo.aggregate(SpawnInput, :count)
n = :counters.get(stores, 1)

IO.puts(
  "#{writers} writers for #{seconds} s: #{n} stores (#{Float.round(n / seconds, 1)} builds/s), #{:counters.get(expired, 1)} expired, #{:counters.get(pruned, 1)} lists pruned concurrently"
)

IO.puts(
  "after: #{spawns} spawns, #{lists} lists, dangling references: #{dangling}, orphans left: #{orphans}"
)

if dangling != 0, do: exit({:shutdown, 1})
