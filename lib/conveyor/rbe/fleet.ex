defmodule Conveyor.Rbe.Fleet do
  @moduledoc """
  The event-stream half of the duplicate-work report: what can be said about a fleet
  whose CI uploads only build events, stored per project and hour in
  `invocation_rollups.fleet`.

  It reads `BuildMetrics` as Conveyor stores it (`invocation_metrics.build_metrics`):

    * `actionSummary.runnerCount`: spawns by runner. Names ending in `cache hit` are
      hits, `total` and `internal` are not spawns, every other name executed;
    * `actionSummary.actionData`: per mnemonic the actions executed (cache hits included)
      and created, and the CPU time (user + system) of the ones that ran, when Bazel
      measured it for all of them. Bazel lists only its top mnemonics by count.

  and the host of each build: a host's first three builds are told apart from its later
  ones (`build_hosts` keeps each host's three earliest starts), which is the signal of a
  machine starting with a cold cache.

  None of this identifies an action, so nothing here is a duplicate: executed work is an
  upper bound of what a better cache or remote execution could save.
  """
  import Ecto.Query

  alias Conveyor.ExecLog.Cores
  alias Conveyor.Invocations.Metrics
  alias Conveyor.Rbe.Host
  alias Conveyor.Repo

  @firsts 3

  @doc "Computes the report of the finished builds `finished` selects."
  @spec compute(Ecto.Query.t()) :: map()
  def compute(finished) do
    builds =
      Repo.all(
        from i in subquery(finished),
          left_join: m in Metrics,
          on: m.invocation_id == i.id,
          select: %{
            project_id: i.project_id,
            host: i.host,
            started_at: i.started_at,
            summary: fragment("? -> 'actionSummary'", m.build_metrics)
          }
      )

    firsts = observe_hosts(builds)
    Enum.reduce(builds, %{"builds" => 0}, &fold(&1, &2, firsts))
  end

  # Records the earliest starts of each host (a minimum: any order of hours gives the same
  # rows) and returns them for the hosts of these builds.
  defp observe_hosts(builds) do
    rows =
      builds
      |> Enum.filter(&(is_binary(&1.host) and &1.started_at != nil))
      |> Enum.group_by(&{&1.project_id, &1.host}, & &1.started_at)
      |> Enum.map(fn {{project_id, host}, starts} ->
        %{
          project_id: project_id,
          host: host,
          firsts: starts |> Enum.uniq() |> Enum.sort(DateTime) |> Enum.take(@firsts)
        }
      end)
      |> Enum.sort_by(&{&1.project_id, &1.host})

    # Only a host whose earliest starts change is written: this runs on read paths too
    # (the partial hours of a window), where nearly every host is already known.
    Enum.each(Enum.chunk_every(rows, 1000), fn chunk ->
      Repo.insert_all(Host, chunk,
        conflict_target: [:project_id, :host],
        on_conflict:
          from(h in Host,
            where:
              fragment(
                "NOT (? @> EXCLUDED.firsts) AND NOT (cardinality(?) >= ? AND ?[?] <= (SELECT min(t) FROM unnest(EXCLUDED.firsts) t))",
                h.firsts,
                h.firsts,
                @firsts,
                h.firsts,
                @firsts
              ),
            update: [
              set: [
                firsts:
                  fragment(
                    "(SELECT coalesce(array_agg(t ORDER BY t), '{}') FROM (SELECT DISTINCT t FROM unnest(? || EXCLUDED.firsts) t ORDER BY t LIMIT ?) x)",
                    h.firsts,
                    @firsts
                  )
              ]
            ]
          )
      )
    end)

    project_ids = rows |> Enum.map(& &1.project_id) |> Enum.uniq()
    hosts = rows |> Enum.map(& &1.host) |> Enum.uniq()

    from(h in Host, where: h.project_id in ^project_ids and h.host in ^hosts)
    |> Repo.all()
    |> Map.new(&{{&1.project_id, &1.host}, &1.firsts})
  end

  defp fold(build, acc, firsts) do
    acc = Map.update!(acc, "builds", &(&1 + 1))

    case build.summary do
      nil ->
        acc

      summary ->
        {hits, executed} = runners(summary)
        cpu = Cores.cpu_ms(%{"actionSummary" => summary})
        cpu_ms = cpu |> Map.values() |> Enum.sum() |> round()

        acc
        |> add(["with_metrics"], 1)
        |> add_runners(summary)
        |> add_mnemonics(summary, cpu)
        |> add_share(hits, executed)
        |> add(["hosts", ordinal(build, firsts)], [1, executed, hits, cpu_ms])
    end
  end

  defp runners(summary) do
    Enum.reduce(summary["runnerCount"] || [], {0, 0}, fn r, {hits, executed} ->
      name = r["name"] || ""
      count = r["count"] || 0

      cond do
        name in ["total", "internal"] -> {hits, executed}
        String.ends_with?(name, "cache hit") -> {hits + count, executed}
        true -> {hits, executed + count}
      end
    end)
  end

  defp add_runners(acc, summary) do
    Enum.reduce(summary["runnerCount"] || [], acc, fn r, acc ->
      if r["name"] in [nil, "total"],
        do: acc,
        else: add(acc, ["runners", r["name"]], r["count"] || 0)
    end)
  end

  defp add_mnemonics(acc, summary, cpu) do
    Enum.reduce(summary["actionData"] || [], acc, fn a, acc ->
      name = a["mnemonic"] || ""

      add(acc, ["mn", name], [
        number(a["actionsExecuted"]),
        number(a["actionsCreated"]),
        round(Map.get(cpu, name, 0)),
        if(Map.has_key?(cpu, name), do: number(a["actionsExecuted"]), else: 0)
      ])
    end)
  end

  # The share of a build's spawns that executed, in tenths.
  defp add_share(acc, hits, executed) when hits + executed > 0 do
    decile = min(9, div(executed * 10, hits + executed))
    acc |> add(["share", Integer.to_string(decile)], 1) |> add(["spawns"], [hits, executed])
  end

  defp add_share(acc, _hits, _executed), do: acc

  defp ordinal(%{host: nil}, _firsts), do: "unknown"

  defp ordinal(build, firsts) do
    case Enum.find_index(
           Map.get(firsts, {build.project_id, build.host}, []),
           &(DateTime.compare(&1, build.started_at) == :eq)
         ) do
      nil -> "later"
      index -> Integer.to_string(index + 1)
    end
  end

  defp number(n) when is_integer(n), do: n

  defp number(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp number(_), do: 0

  defp add(acc, [key], value), do: Map.update(acc, key, value, &Conveyor.Rbe.sum(&1, value))

  defp add(acc, [key | rest], value),
    do: Map.put(acc, key, add(Map.get(acc, key, %{}), rest, value))

  @doc "Deletes the hosts of a project whose first build is older than `cutoff`."
  @spec prune!(integer(), DateTime.t()) :: non_neg_integer()
  def prune!(project_id, cutoff) do
    {n, _} =
      Repo.delete_all(
        from h in Host,
          where: h.project_id == ^project_id and fragment("?[1] < ?", h.firsts, ^cutoff)
      )

    n
  end
end
