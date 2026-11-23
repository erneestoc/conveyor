defmodule Conveyor.Rbe.Report do
  @moduledoc """
  The duplicate-work report of a window, read from the hourly rollups
  (`Conveyor.Metrics.Rollup.rows/1`: stored hours plus the two partial edges).

  Times are milliseconds of wall time (`ms`) and of core time (`core_ms` = wall × cores).
  The cores of an action are its exec property when it has one; otherwise the project's
  `mnemonic → cores` setting when it has one, otherwise what the parse estimated
  (`Conveyor.ExecLog.Cores`).

  Tenancy: `visible` is the set of projects the viewer may see. Rows about any other
  project (a group's member the viewer has no access to) carry no name and no target:
  they are summed into one "other projects" entry.
  """
  alias Conveyor.Metrics.{Rollup, Scope}
  alias Conveyor.Rbe.{Hour, Settings}

  @type opts :: [
          settings: Settings.t(),
          visible: :all | [integer()],
          names: %{integer() => String.t()}
        ]

  @zero %{n: 0, ms: 0, core_ms: 0}

  @spec build(Scope.t(), opts()) :: map()
  def build(%Scope{} = scope, opts) do
    settings = Keyword.fetch!(opts, :settings)
    visible = Keyword.get(opts, :visible, :all)
    names = Keyword.get(opts, :names, %{})
    rows = Rollup.rows(scope)
    row = Rollup.combine(rows)
    rbe = row.rbe || %{}
    logged_days = logged_days(rows)
    cores = settings.cores
    days = max(DateTime.diff(scope.to, scope.from, :second) / 86_400, 1 / 24)

    mn = rbe["mn"] || %{}
    class = fn names -> names |> Enum.map(&total(mn[&1], cores)) |> add() end
    hits = class.(["hit"])
    first = class.(["first"])
    racing = class.(Hour.racing())
    local = total(rbe["local"], cores)
    same = class.(["seq"])
    cross = class.(["seq_x"])
    other = class.(~w(failed uncacheable unkeyed))
    executed = add([first, racing, same, cross, other])
    spawns = hits.n + executed.n
    sequential = add([same, cross])

    today = rate(hits.n, spawns)
    perfect = rate(hits.n + sequential.n, spawns)
    dedup = rate(hits.n + sequential.n + racing.n - local.n, spawns)
    cold = total(rbe["cold"], cores)

    %{
      days: days,
      # UTC days (of the build's start) with at least one build whose log was parsed,
      # and the UTC days the window touches: what a "per logged day" figure divides by.
      logged_days: logged_days,
      window_days: Date.diff(DateTime.to_date(scope.to), DateTime.to_date(scope.from)) + 1,
      per_logged_day: %{
        sequential: per_day(sequential, logged_days),
        racing: per_day(sub(racing, local), logged_days),
        cold: per_day(cold, logged_days)
      },
      coverage: %{builds: row.succeeded + row.failed + row.aborted, logs: rbe["builds"] || 0},
      # Where the figures above come from, and the same analysis from the event stream
      # alone for the builds without a parsed log (`Conveyor.Rbe.Stream`).
      source: source(rbe),
      stream:
        stream(
          rbe["stream"],
          cores,
          row.succeeded + row.failed + row.aborted,
          rows,
          visible,
          names
        ),
      keys: rbe["keys"] || %{},
      executed: executed,
      cache: %{
        hits: hits.n,
        spawns: spawns,
        hit_rate: %{today: today, perfect_cache: perfect, with_in_flight_deduplication: dedup},
        # the names of the first release, kept as aliases for one more
        actual_rate: today,
        ideal_rate: perfect,
        rbe_rate: dedup,
        gap: sequential,
        gap_time_share: rate(sequential.ms, executed.ms),
        same_project: same,
        cross_project: cross,
        cold: cold
      },
      racing: %{
        total: racing,
        remotable: sub(racing, local),
        local: local,
        cross_project: class.(["racing_x"]),
        time_share: rate(racing.ms - local.ms, executed.ms),
        uncertain: uncertain(rbe["band"] || %{}, settings.tolerance_s, cores)
      },
      not_dedupable: %{
        nonremote: total(rbe["nonremote"], cores),
        uncacheable: class.(["uncacheable"]),
        failed: class.(["failed"]),
        unkeyed: class.(["unkeyed"])
      },
      nondet: total(rbe["nondet"], cores),
      near: %{
        n: Enum.at(rbe["near"] || [0, 0], 0),
        ms: Enum.at(rbe["near"] || [0, 0], 1),
        examples: Enum.filter(rbe["near_ex"] || [], &visible?(&1["project"], visible))
      },
      parallelism: parallelism(rbe["par"]),
      cores_coverage: cores_coverage(rbe["src"] || %{}, rbe["srcn"] || %{}, executed),
      mnemonics: mnemonics(mn, rbe["src"] || %{}, cores),
      targets: targets(rbe["tgt"] || %{}, cores, visible, names),
      projects: projects(rbe, cores, visible, names),
      pipelines: pipelines(rbe["pipe"] || %{}, cores, visible),
      fleet: fleet(row.fleet || %{})
    }
  end

  defp source(rbe) do
    case {(rbe["builds"] || 0) > 0, (get_in(rbe, ["stream", "builds"]) || 0) > 0} do
      {true, true} -> "both"
      {true, false} -> "execution_log"
      {false, true} -> "stream"
      {false, false} -> "none"
    end
  end

  # Two figures per class: against the key at the build's commit (a floor: duplicates at
  # one commit, exact) and against the key at any commit (a ceiling: every duplicate,
  # and actions whose inputs changed without changing their command line).
  defp stream(nil, _cores, _builds, _rows, _visible, _names), do: nil

  defp stream(s, cores, builds, rows, visible, names) do
    figure = fn space ->
      classes = s[space] || %{}
      cell = fn names -> names |> Enum.map(&total(classes[&1], cores)) |> add() end
      racing = cell.(Hour.racing())
      sequential = cell.(Hour.sequential())
      executed = cell.(["first", "nocommit" | Hour.dups()])

      %{
        first: cell.(["first"]),
        racing: racing,
        sequential: sequential,
        cross_project: cell.(~w(racing_x seq_x)),
        duplicate: add([racing, sequential]),
        duplicate_time_share: rate(racing.ms + sequential.ms, executed.ms),
        no_commit: cell.(["nocommit"]),
        executed: executed
      }
    end

    any = figure.("any")
    same = figure.("same")
    hits = total(s["hit"], cores)
    spawns = hits.n + any.executed.n
    days = stream_days(rows)

    %{
      builds: s["builds"] || 0,
      counts_only_builds: s["counts_only"] || 0,
      no_commit_builds: s["no_commit"] || 0,
      pending_builds: s["pending"] || 0,
      logged_builds: s["logged"] || 0,
      # builds merged after their hour's figures were final (not in them)
      late_builds: s["late"] || 0,
      # builds that sent per-action events, of the finished builds of the window
      coverage: %{builds: builds, with_events: s["events"] || 0},
      executed: any.executed,
      hits: hits,
      untimed: total(s["untimed"], cores).n,
      same_commit: same,
      any_commit: any,
      estimate: estimate(s, same, any, cores),
      # UTC days with at least one build reported from its per-action events
      days: days,
      per_day: %{
        same_commit: %{
          sequential: per_day(same.sequential, days),
          racing: per_day(same.racing, days)
        },
        any_commit: %{
          sequential: per_day(any.sequential, days),
          racing: per_day(any.racing, days)
        }
      },
      # today; with a cache every build reads (sequential duplicates become hits); and
      # with deduplication of actions in flight as well. `[same commit, any commit]`.
      hit_rate: %{
        today: rate(hits.n, spawns),
        perfect_cache: for(f <- [same, any], do: rate(hits.n + f.sequential.n, spawns)),
        with_in_flight_deduplication:
          for(f <- [same, any], do: rate(hits.n + f.duplicate.n, spawns))
      },
      mnemonics: stream_mnemonics(s, cores),
      targets: stream_targets(s["tgt"] || %{}, cores, visible, names)
    }
  end

  defp stream_days(rows) do
    rows
    |> Enum.filter(&((get_in(&1.rbe || %{}, ["stream", "builds"]) || 0) > 0))
    |> Enum.map(&DateTime.to_date(&1.hour))
    |> Enum.uniq()
    |> length()
  end

  # The estimate between the two figures (PLAN §28.4). An execution that repeats its key
  # only across commits is a duplicate when the work did not change between them. The
  # stream decides that for some (`different`: the build read the cache of the build
  # that had finished the key, and ran it anyway) and leaves the rest `unknown`. Of the
  # unknown ones the estimate counts the share of actions that builds with the earlier
  # result at hand found unchanged across commits: `unchanged ÷ (unchanged + different)`
  # per mnemonic, in count for counts and in time for times; the share over all
  # mnemonics where a mnemonic has no such observation. Without any observation and
  # with something unknown there is no estimate (nil).
  defp estimate(s, same, any, cores) do
    est = s["est"] || %{}
    xhit = est["xhit"] || %{}
    diff = est["diff"] || %{}
    unk = est["unk"] || %{}
    unchanged = total(xhit, cores)
    different = total(diff, cores)
    all = fn classes -> classes |> Enum.map(&total(unk[&1], cores)) |> add() end
    unknown = all.(Hour.dups())
    overall = share(unchanged, different)

    scaled = fn classes ->
      for class <- classes, {mnemonic, cell} <- unk[class] || %{} do
        c = one(mnemonic, cell, cores)

        {n, t} =
          share(
            one(mnemonic, xhit[mnemonic] || [0, 0, 0, 0, 0], cores),
            one(mnemonic, diff[mnemonic] || [0, 0, 0, 0, 0], cores)
          ) || overall

        %{n: round(c.n * n), ms: round(c.ms * t), core_ms: round(c.core_ms * t)}
      end
      |> add()
    end

    if unknown.n > 0 and overall == nil do
      nil
    else
      # Never below the floor, never above the ceiling, class by class.
      figure = fn classes, floor, ceiling ->
        e = add([floor, scaled.(classes)])

        %{
          n: e.n |> min(max(ceiling.n, floor.n)),
          ms: e.ms |> min(max(ceiling.ms, floor.ms)),
          core_ms: e.core_ms |> min(max(ceiling.core_ms, floor.core_ms))
        }
      end

      racing = figure.(Hour.racing(), same.racing, any.racing)
      sequential = figure.(Hour.sequential(), same.sequential, any.sequential)

      %{
        racing: racing,
        sequential: sequential,
        cross_project: figure.(~w(racing_x seq_x), same.cross_project, any.cross_project),
        duplicate: add([racing, sequential]),
        duplicate_time_share: rate(racing.ms + sequential.ms, any.executed.ms),
        # what the estimate rests on
        evidence: %{
          unchanged: unchanged,
          different: different,
          unknown: unknown,
          share: overall && %{n: elem(overall, 0), ms: elem(overall, 1)}
        }
      }
    end
  end

  defp share(unchanged, different) do
    if unchanged.n + different.n > 0 do
      {unchanged.n / (unchanged.n + different.n),
       if(unchanged.ms + different.ms > 0,
         do: unchanged.ms / (unchanged.ms + different.ms),
         else: unchanged.n / (unchanged.n + different.n)
       )}
    end
  end

  defp stream_mnemonics(s, cores) do
    spaces = [s["any"] || %{}, s["same"] || %{}]

    names =
      [s["hit"] || %{} | Enum.flat_map(spaces, &Map.values/1)]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    for name <- names do
      cell = fn space, classes ->
        classes |> Enum.map(&total(Map.take(space[&1] || %{}, [name]), cores)) |> add()
      end

      [any, same] = spaces
      executed = cell.(any, ["first" | Hour.dups()])

      %{
        mnemonic: name,
        hits: total(Map.take(s["hit"] || %{}, [name]), cores).n,
        executed: executed,
        cores: if(executed.ms > 0, do: executed.core_ms / executed.ms),
        cores_source:
          if(Map.has_key?(cores, name), do: "project setting", else: "cpu time ÷ wall time"),
        same_commit: %{
          racing: cell.(same, Hour.racing()),
          sequential: cell.(same, Hour.sequential())
        },
        any_commit: %{
          racing: cell.(any, Hour.racing()),
          sequential: cell.(any, Hour.sequential())
        }
      }
    end
    |> Enum.sort_by(fn m ->
      {-(m.any_commit.racing.core_ms + m.any_commit.sequential.core_ms), -m.executed.core_ms,
       m.mnemonic}
    end)
  end

  # A target's cells have no mnemonic: the cores are those measured in its builds.
  defp stream_targets(by_project, _cores, visible, names) do
    for {pid, labels} <- by_project, visible?(pid, visible), {label, classes} <- labels do
      cell = fn names ->
        names
        |> Enum.map(&(classes[&1] || [0, 0, 0]))
        |> Enum.reduce(@zero, fn [n, ms, core_ms], acc ->
          %{n: acc.n + n, ms: acc.ms + ms, core_ms: acc.core_ms + core_ms}
        end)
      end

      space = fn prefix ->
        %{
          racing: cell.(Enum.map(Hour.racing(), &(prefix <> &1))),
          sequential: cell.(Enum.map(Hour.sequential(), &(prefix <> &1)))
        }
      end

      %{
        project: name(pid, names),
        target: label,
        same_commit: space.("same_"),
        any_commit: space.("any_")
      }
    end
    |> Enum.sort_by(fn t ->
      {-(t.any_commit.racing.core_ms + t.any_commit.sequential.core_ms), t.target}
    end)
    |> Enum.take(20)
  end

  # --- cells ---------------------------------------------------------------------------------

  # The sum of a `mnemonic → cell` map, with the project's cores applied to the part
  # whose cores are not exact.
  defp total(nil, _cores), do: @zero

  defp total(by_mnemonic, cores) do
    Enum.reduce(by_mnemonic, @zero, fn {mnemonic, cell}, acc ->
      add([acc, one(mnemonic, cell, cores)])
    end)
  end

  defp one(mnemonic, [n, ms, core_ms, exact_ms, exact_core_ms], cores) do
    core_ms =
      case Map.get(cores, mnemonic) do
        nil -> core_ms
        c -> round(exact_core_ms + (ms - exact_ms) * c)
      end

    %{n: n, ms: ms, core_ms: core_ms}
  end

  defp add(cells) do
    Enum.reduce(cells, @zero, fn c, acc ->
      %{n: acc.n + c.n, ms: acc.ms + c.ms, core_ms: acc.core_ms + c.core_ms}
    end)
  end

  # A day is the UTC day of a build's start: the day of the hour it is summarized in.
  # (The window's last, partly computed bucket of up to two hours counts as the day it
  # starts in.)
  defp logged_days(rows) do
    rows
    |> Enum.filter(&(((&1.rbe || %{})["builds"] || 0) > 0))
    |> Enum.map(&DateTime.to_date(&1.hour))
    |> Enum.uniq()
    |> length()
  end

  defp per_day(_cell, 0), do: nil

  defp per_day(cell, days),
    do: %{n: cell.n / days, ms: round(cell.ms / days), core_ms: round(cell.core_ms / days)}

  defp sub(a, b), do: %{n: a.n - b.n, ms: a.ms - b.ms, core_ms: a.core_ms - b.core_ms}

  defp rate(_n, 0), do: nil
  defp rate(n, d), do: n / d

  # Executions whose start is within the tolerance of the first one's finish: with clocks
  # that far apart, each could belong to the other class.
  defp uncertain(band, tolerance, cores) do
    within = fn classes ->
      for class <- classes,
          {bucket, cells} <- Map.get(band, class, %{}),
          String.to_integer(bucket) <= tolerance do
        total(cells, cores)
      end
      |> add()
    end

    %{
      tolerance_s: tolerance,
      racing: within.(Hour.racing()),
      sequential: within.(Hour.sequential())
    }
  end

  defp parallelism([builds, action_ms, critical_ms, phase_ms, with_path]) when builds > 0 do
    %{
      builds: builds,
      action_ms: action_ms,
      # what the builds achieved: action time per second of execution phase
      achieved: rate(action_ms, phase_ms),
      # the most any number of cores could use: action time per second of critical path
      bound: if(with_path == builds, do: rate(action_ms, critical_ms))
    }
  end

  defp parallelism(_), do: nil

  # How much of what executed states its cores in an exec property (the exact source),
  # by wall time and by count, and what the rest fell back to. Counts per source are kept
  # by hours summarized since they existed: `n` is nil while the window still holds an
  # hour without them.
  defp cores_coverage(src, srcn, executed) do
    ms = by_source(src)
    n = by_source(srcn)
    counted? = n |> Map.values() |> Enum.sum() == executed.n

    %{
      executed: %{n: executed.n, ms: executed.ms},
      exact: %{n: if(counted?, do: Map.get(n, "exec property", 0)), ms: ms["exec property"] || 0},
      exact_share: rate(ms["exec property"] || 0, executed.ms),
      fallbacks:
        for {name, wall} <- ms, name != "exec property" do
          %{source: name, n: if(counted?, do: Map.get(n, name, 0)), ms: wall}
        end
        |> Enum.sort_by(&{-&1.ms, &1.source})
    }
  end

  defp by_source(by_mnemonic) do
    by_mnemonic
    |> Map.values()
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _source, a, b -> a + b end))
  end

  # --- tables --------------------------------------------------------------------------------

  defp mnemonics(mn, sources, cores) do
    names = mn |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    for name <- names do
      cell = fn classes ->
        classes |> Enum.map(&total(Map.take(mn[&1] || %{}, [name]), cores)) |> add()
      end

      executed = cell.(~w(first racing racing_x seq seq_x failed uncacheable unkeyed))

      %{
        mnemonic: name,
        hits: cell.(["hit"]).n,
        executed: executed,
        cores: if(executed.ms > 0, do: executed.core_ms / executed.ms),
        cores_source: source(Map.get(sources, name, %{}), Map.has_key?(cores, name)),
        exact_share: exact_share(Map.get(sources, name, %{})),
        racing: cell.(Hour.racing()),
        sequential: cell.(Hour.sequential())
      }
    end
    |> Enum.sort_by(
      &{-(&1.racing.core_ms + &1.sequential.core_ms), -&1.executed.core_ms, &1.mnemonic}
    )
  end

  # The share of a mnemonic's executed wall time whose cores an exec property states.
  defp exact_share(by_source),
    do: rate(Map.get(by_source, "exec property", 0), by_source |> Map.values() |> Enum.sum())

  # Where a mnemonic's cores come from, by the wall time each source covers.
  defp source(by_source, override?) do
    exact = Map.get(by_source, "exec property", 0)
    all = by_source |> Map.values() |> Enum.sum()

    estimated =
      if override? do
        "project setting"
      else
        by_source
        |> Map.delete("exec property")
        |> Enum.max_by(fn {name, ms} -> {ms, name} end, fn -> {"default", 0} end)
        |> elem(0)
      end

    cond do
      all > 0 and exact == all -> "exec property"
      exact > 0 -> "exec property + " <> estimated
      true -> estimated
    end
  end

  defp targets(by_project, cores, visible, names) do
    for {pid, labels} <- by_project, visible?(pid, visible), {label, classes} <- labels do
      cell = fn names -> names |> Enum.map(&total(classes[&1], cores)) |> add() end

      %{
        project: name(pid, names),
        target: label,
        racing: cell.(Hour.racing()),
        sequential: cell.(Hour.sequential())
      }
    end
    |> Enum.sort_by(&{-(&1.racing.core_ms + &1.sequential.core_ms), &1.target})
    |> Enum.take(20)
  end

  # Per project: what it executed, what it redid, how much of it other projects of the
  # group also executed, and whose finished work it redid. Projects the viewer cannot see
  # are one row without a name.
  defp projects(rbe, cores, visible, names) do
    rows =
      for {pid, classes} <- rbe["proj"] || %{} do
        cell = fn names -> names |> Enum.map(&total(classes[&1], cores)) |> add() end
        executed = cell.(~w(first racing racing_x seq seq_x))

        %{
          id: pid,
          executed: executed,
          racing: cell.(Hour.racing()),
          sequential: cell.(["seq"]),
          cross: cell.(["seq_x"]),
          shared: total(get_in(rbe, ["multi", pid]), cores),
          from:
            for(
              {from, cells} <- get_in(rbe, ["from", pid]) || %{},
              do: {from, total(cells, cores)}
            )
        }
      end

    {seen, hidden} = Enum.split_with(rows, &visible?(&1.id, visible))

    seen =
      seen
      |> Enum.map(fn r ->
        r
        |> Map.put(:name, name(r.id, names))
        |> Map.put(:shared_share, rate(r.shared.ms, r.executed.ms))
        |> Map.update!(:from, &origins(&1, visible, names))
      end)
      |> Enum.sort_by(&{-wasted(&1), &1.name})

    %{
      rows: seen,
      others:
        if hidden != [] do
          %{
            count: length(hidden),
            executed: hidden |> Enum.map(& &1.executed) |> add(),
            racing: hidden |> Enum.map(& &1.racing) |> add(),
            sequential: hidden |> Enum.map(& &1.sequential) |> add(),
            cross: hidden |> Enum.map(& &1.cross) |> add()
          }
        end
    }
  end

  defp wasted(r), do: r.racing.core_ms + r.sequential.core_ms + r.cross.core_ms

  defp origins(from, visible, names) do
    {seen, hidden} =
      Enum.split_with(from, fn {pid, _} -> pid != "gone" and visible?(pid, visible) end)

    seen = Enum.map(seen, fn {pid, cell} -> %{id: pid, name: name(pid, names), cell: cell} end)

    others =
      case hidden do
        [] ->
          []

        cells ->
          [%{id: nil, name: "other projects", cell: cells |> Enum.map(&elem(&1, 1)) |> add()}]
      end

    Enum.sort_by(seen, &{-&1.cell.core_ms, &1.name}) ++ others
  end

  defp pipelines(by_project, cores, visible) do
    for {pid, values} <- by_project, visible?(pid, visible), {value, cells} <- values do
      Map.put(total(cells, cores), :value, value)
    end
    |> Enum.sort_by(&{-&1.core_ms, &1.value})
    |> Enum.take(10)
  end

  defp visible?(_pid, :all), do: true
  defp visible?(pid, ids) when is_binary(pid), do: String.to_integer(pid) in ids
  defp visible?(pid, ids), do: pid in ids

  defp name(pid, names), do: Map.get(names, String.to_integer(pid), "project " <> pid)

  # --- the event-stream bound ------------------------------------------------------------------

  defp fleet(fleet) do
    [hits, executed] = fleet["spawns"] || [0, 0]
    hosts = fleet["hosts"] || %{}
    later = host(hosts["later"])
    cold = for o <- ~w(1 2 3), do: Map.put(host(hosts[o]), :ordinal, String.to_integer(o))

    %{
      builds: fleet["builds"] || 0,
      with_metrics: fleet["with_metrics"] || 0,
      hits: hits,
      executed: executed,
      executed_share: rate(executed, hits + executed),
      runners:
        (fleet["runners"] || %{})
        |> Enum.sort_by(fn {name, n} -> {-n, name} end)
        |> Enum.map(fn {name, n} -> %{name: name, count: n} end),
      share: for(d <- 0..9, do: get_in(fleet, ["share", Integer.to_string(d)]) || 0),
      mnemonics:
        for {name, [executed, created, cpu_ms, timed]} <- fleet["mn"] || %{} do
          %{mnemonic: name, executed: executed, created: created, cpu_ms: cpu_ms, timed: timed}
        end
        |> Enum.sort_by(&{-&1.cpu_ms, -&1.executed, &1.mnemonic}),
      cpu_ms: (fleet["mn"] || %{}) |> Map.values() |> Enum.map(&Enum.at(&1, 2)) |> Enum.sum(),
      hosts: %{
        cold: cold,
        later: later,
        unknown: host(hosts["unknown"]),
        excess: excess(cold, later)
      }
    }
  end

  defp host(nil), do: %{builds: 0, executed: 0, hits: 0, cpu_ms: 0}

  defp host([builds, executed, hits, cpu_ms]),
    do: %{builds: builds, executed: executed, hits: hits, cpu_ms: cpu_ms}

  # What the first builds of hosts executed beyond what a later build of a host executes
  # on average: the cost of starting cold, as far as the event stream shows it.
  defp excess(_cold, %{builds: 0}), do: nil

  defp excess(cold, later) do
    builds = cold |> Enum.map(& &1.builds) |> Enum.sum()

    %{
      builds: builds,
      executed:
        max(
          0,
          round(Enum.sum(Enum.map(cold, & &1.executed)) - builds * later.executed / later.builds)
        ),
      cpu_ms:
        max(
          0,
          round(Enum.sum(Enum.map(cold, & &1.cpu_ms)) - builds * later.cpu_ms / later.builds)
        )
    }
  end

  @doc "The report as JSON-ready data (the API's body)."
  @spec to_json(map()) :: map()
  def to_json(report), do: report |> Jason.encode!() |> Jason.decode!()
end
