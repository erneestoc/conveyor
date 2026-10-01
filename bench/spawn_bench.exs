# Execution-log storage benchmark: parses real logs once, stores each as N builds of one
# project (the shape of a repo building the same commit repeatedly), and reports table
# sizes, store time and the per-action diff time. Works before and after deduplication.
#   MIX_ENV=prod DATABASE_URL=... mix run --no-start bench/spawn_bench.exs LOGDIR N  (LOGDIR holds compact execution logs)
Logger.configure(level: :warning)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)
{:ok, _} = Conveyor.Repo.start_link()
import Ecto.Query
alias Conveyor.{ExecLog, Repo}
alias Conveyor.Invocations.Invocation

[dir, n] = System.argv()
n = String.to_integer(n)
project = Conveyor.Projects.ensure_default_project!()

Repo.query!("TRUNCATE spawns")

if Repo.exists?(from t in "pg_tables", where: t.tablename == "spawn_inputs"),
  do: Repo.query!("TRUNCATE spawn_inputs")

Repo.delete_all(from i in Invocation, where: i.project_id == ^project.id)
Repo.query!("VACUUM FULL spawns")

sizes = fn ->
  %{rows: rows} =
    Repo.query!(
      "SELECT relname, pg_total_relation_size(oid), pg_relation_size(oid) FROM pg_class WHERE relname IN ('spawns','spawn_inputs')"
    )

  Map.new(rows, fn [r, t, h] -> {r, {t, h}} end)
end

logs =
  dir
  |> File.ls!()
  |> Enum.sort()
  |> Enum.map(fn f ->
    {:ok, parsed} = ExecLog.parse(File.read!(Path.join(dir, f)))
    {f, parsed}
  end)

IO.puts(
  "logs: #{Enum.map_join(logs, ", ", fn {f, p} -> "#{f} (#{length(p.spawns)} spawns)" end)}; #{n} builds each"
)

now = DateTime.utc_now()

invs =
  for {f, _} <- logs, k <- 1..n do
    at = DateTime.add(now, -(k * 3600), :second)

    Repo.insert!(%Invocation{
      id: Ecto.UUID.generate(),
      project_id: project.id,
      status: "succeeded",
      tags: %{"branch" => "main", "log" => f},
      inserted_at: at,
      updated_at: at,
      started_at: at
    })
    |> then(&{f, &1})
  end

{store_us, _} =
  :timer.tc(fn ->
    for {f, inv} <- invs do
      {_, parsed} = List.keyfind(logs, f, 0)
      ExecLog.store!(inv, parsed)
    end
  end)

builds = length(invs)
spawns = Repo.aggregate(ExecLog.Spawn, :count)
s = sizes.()
{spawn_total, _} = s["spawns"]
{inputs_total, _} = Map.get(s, "spawn_inputs", {0, 0})
total = spawn_total + inputs_total

IO.puts(
  "stored #{builds} builds, #{spawns} spawns in #{Float.round(store_us / 1.0e6, 1)} s (#{div(store_us, builds * 1000)} ms/build)"
)

IO.puts(
  "spawns table #{div(spawn_total, 1024 * 1024)} MB, spawn_inputs #{div(inputs_total, 1024 * 1024)} MB, total #{div(total, 1024 * 1024)} MB = #{div(total, builds * 1024)} KB/build"
)

distinct = Repo.one(from s in ExecLog.Spawn, select: count(s.inputs_digest, :distinct))
IO.puts("distinct input lists: #{distinct} of #{spawns}")

# read side: explain (digest comparison) and the per-action diff (reads two lists)
{_, inv} = Enum.at(invs, 1)
{explain_us, explained} = :timer.tc(fn -> ExecLog.explain(inv) end)
[a, b | _] = ExecLog.list(inv)
{diff_us, _} = :timer.tc(fn -> ExecLog.diff(a, b) end)
{inputs_us, inputs} = :timer.tc(fn -> ExecLog.inputs(a) end)

IO.puts(
  "explain #{div(explain_us, 1000)} ms (#{length(explained.rows)} rows), one diff #{div(diff_us, 1000)} ms, one inputs read #{div(inputs_us, 1000)} ms (#{length(inputs)} paths)"
)

# retention: delete half the builds' spawns, then prune orphan lists when available
half = invs |> Enum.take(div(builds, 2)) |> Enum.map(fn {_, i} -> i.id end)

{del_us, _} =
  :timer.tc(fn ->
    Repo.delete_all(from(s in ExecLog.Spawn, where: s.invocation_id in ^half), timeout: :infinity)
  end)

IO.puts("deleted spawns of #{length(half)} builds in #{div(del_us, 1000)} ms")

if function_exported?(ExecLog, :prune_orphan_inputs, 2) do
  {prune_us, pruned} = :timer.tc(fn -> ExecLog.prune_orphan_inputs(DateTime.utc_now(), 0) end)
  s2 = sizes.()
  {it, _} = Map.get(s2, "spawn_inputs", {0, 0})

  IO.puts(
    "pruned #{pruned} orphan lists in #{div(prune_us, 1000)} ms; spawn_inputs now #{div(it, 1024 * 1024)} MB"
  )
end
