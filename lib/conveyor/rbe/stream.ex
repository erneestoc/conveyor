defmodule Conveyor.Rbe.Stream do
  @moduledoc """
  Duplicate work from the event stream alone (PLAN §28): for builds run with
  `--build_event_publish_all_actions` (Bazel 8.6 and later) and nothing else.

  The ingest path leaves a compact record per successful action in chunks
  (`Conveyor.Rbe.StreamActions`, `Conveyor.Rbe.StreamChunk`). This module does the rest:

    * `merge_keys!/1`, once a build is finished: its executions are merged into
      `action_keys` (the table and the rule of `Conveyor.ExecLog.Keys`: per scope and
      key, the execution that finished first) under **two keys each**: the stream key
      (any commit) and the stream key hashed with the build's commit (same commit; only
      when the build names one, `commit/1`). Builds whose classes may have changed are
      made stale, so their hours are rolled again.
    * `hour/1`, when an hour is rolled: every execution of the hour's builds is classed
      against the rows of its two keys, by primary key. Nothing stores a class.
    * the report's two figures: the same-commit one is a **floor** (at one commit the
      key identifies an action exactly, so these are duplicates; duplicates across
      commits are missing), the any-commit one a **ceiling** (an action whose inputs
      changed between commits keeps its key when its command line does not name them,
      so some of these are not duplicates; every real duplicate is among them).

  A build whose execution log was parsed is reported from the log and its records are
  ignored here. A build without usable times (Bazel 7; 8.0 to 8.5) is counted only.
  """
  import Ecto.Query

  alias Conveyor.ExecLog
  alias Conveyor.ExecLog.{ActionKey, Cores, Keys}
  alias Conveyor.Invocations.{Invocation, Metrics}
  alias Conveyor.Projects
  alias Conveyor.Rbe.{Groups, Settings, StreamActions, StreamChunk}
  alias Conveyor.Repo

  @timeout :timer.minutes(5)
  @chunk 5_000
  @top 50
  @finished ["succeeded", "failed", "aborted"]
  # How far a build's actions may lie outside `[started_at, finished_at]` (clock
  # readings of one machine, rounded differently).
  @margin_s 60

  @commit_tags ~w(commit commit_sha git_commit build_scm_revision stable_git_commit)

  @doc "The per-action records of a build, in stream order."
  @spec records(String.t()) :: [StreamActions.action()]
  def records(invocation_id) do
    from(c in StreamChunk,
      where: c.invocation_id == ^invocation_id,
      order_by: c.first_seq,
      select: c.records
    )
    |> Repo.all()
    |> Enum.flat_map(&StreamActions.decode/1)
  end

  @doc """
  The commit a build ran at, from the tags Conveyor already keeps (`--build_metadata`,
  workspace status, keywords, API key tags): `commit`, else the usual names of a
  workspace status command. Nil when the build names none: then it has no same-commit
  figure.
  """
  @spec commit(map() | nil) :: String.t() | nil
  def commit(tags) when is_map(tags), do: Enum.find_value(@commit_tags, &tags[&1])
  def commit(_), do: nil

  # --- keys ----------------------------------------------------------------------------------

  @doc "The same-commit key of a stream key: 8 bytes, never equal to a stream key by chance."
  @spec commit_key(binary(), String.t()) :: binary()
  def commit_key(key, commit) do
    <<k::binary-size(8), _::binary>> =
      :crypto.hash(:sha256, ["conveyor-stream-commit-v1\0", key, commit])

    k
  end

  @doc """
  Merges the keys of every finished build since `since` that has records not merged yet
  (or received events after its merge: a stream that came back). Returns how many.
  """
  @spec merge_pending!(DateTime.t()) :: non_neg_integer()
  def merge_pending!(since) do
    from(i in Invocation,
      where: i.stream_actions > 0 and i.started_at >= ^since and i.status in @finished,
      where: is_nil(i.stream_keys_at) or i.last_event_at > i.stream_keys_at,
      order_by: [i.started_at, i.id]
    )
    |> Repo.all(timeout: @timeout)
    |> Enum.map(&merge_keys!/1)
    |> length()
  end

  @doc """
  Merges a build's executions into `action_keys`, in one transaction: the build's chunks
  become one (the string tables of the batches are stored once), the first execution per
  key and per key-at-commit is merged into the project's scope and its cache group's, and
  the builds whose classes may have changed are made stale together with this one.

  Idempotent (a minimum merged twice is the same minimum). Which builds are made stale:
  a row that moves from a first finish `F_old` to an earlier `F_new` changes the class of
  the execution that was first (its build's span holds `F_old`) and of executions that
  started in `[F_new, F_old)`, nothing else. So the builds of the scope with records
  whose span overlaps `[min F_new, max F_old]` over the rows that moved are touched, and
  the builds that held the old firsts. With builds arriving in the order they ran no row
  moves and nothing but the build itself is touched.
  """
  @spec merge_keys!(Invocation.t()) :: :ok
  def merge_keys!(%Invocation{id: id, project_id: project_id} = inv) do
    scopes = project_id |> Projects.get_project!() |> Groups.scopes()

    {:ok, :ok} =
      Conveyor.Ingest.Retry.with_backoff(
        fn ->
          Repo.transaction(
            fn ->
              Repo.query!(
                "SELECT pg_advisory_xact_lock(hashtextextended('stream:' || $1::text, 0))",
                [id],
                timeout: @timeout
              )

              now = DateTime.utc_now()
              entries = id |> compact!() |> entries(commit(inv.tags))

              affected =
                Enum.flat_map(scopes, fn {scope, project_ids} ->
                  merge_scope(scope, project_ids, inv, entries, now)
                end)

              Repo.update_all(from(i in Invocation, where: i.id == ^id),
                set: [stream_keys_at: now]
              )

              Keys.touch!([id | affected], DateTime.utc_now())
            end,
            timeout: @timeout
          )
        end,
        label: "stream keys #{id}"
      )

    :ok
  end

  # The build's records; several chunks are rewritten as one.
  defp compact!(id) do
    chunks =
      Repo.all(
        from(c in StreamChunk, where: c.invocation_id == ^id, order_by: c.first_seq),
        timeout: @timeout
      )

    records = Enum.flat_map(chunks, &StreamActions.decode(&1.records))

    with [first, _ | _] <- chunks do
      seqs = Enum.map(chunks, & &1.first_seq)

      Repo.delete_all(
        from(c in StreamChunk, where: c.invocation_id == ^id and c.first_seq in ^seqs),
        timeout: @timeout
      )

      Repo.insert_all(StreamChunk, [
        %{
          invocation_id: id,
          first_seq: first.first_seq,
          day: first.day,
          n: length(records),
          records: StreamActions.encode(records)
        }
      ])
    end

    records
  end

  @doc """
  One entry per key of a build's records (the shape `Conveyor.ExecLog.Keys.merge!/4`
  takes), under the stream key and, with a commit, under the key at that commit.
  Sorted by key.
  """
  @spec entries([StreamActions.action()], String.t() | nil) :: [map()]
  def entries(records, commit) do
    executions = Enum.filter(records, &StreamActions.execution?/1)

    by_commit =
      if commit,
        do: Enum.group_by(executions, &commit_key(elem(&1, 0), commit)),
        else: %{}

    executions
    |> Enum.group_by(&elem(&1, 0))
    |> Map.merge(by_commit)
    |> Enum.map(fn {key, execs} ->
      {_, start, duration, _, _, _, seq} = Enum.min_by(execs, &rank/1)

      %{
        key: key,
        finish: datetime(start + duration),
        start: datetime(start),
        ordinal: seq,
        last_finish: execs |> Enum.map(&(elem(&1, 1) + elem(&1, 2))) |> Enum.max() |> datetime(),
        # The stream says nothing about outputs: one constant, never "non-deterministic".
        out: "0000000000000000",
        nondet: false
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp rank({_key, start, duration, _mnemonic, _label, _hit, seq}),
    do: {start + duration, start, seq}

  defp datetime(us), do: DateTime.from_unix!(us, :microsecond)

  defp merge_scope(scope, project_ids, inv, entries, now) do
    before = rows(scope, Enum.map(entries, & &1.key))

    case Keys.merge!(scope, inv.id, inv.project_id, entries) do
      [] ->
        []

      changed ->
        changed = MapSet.new(changed)
        moved = Enum.filter(entries, &MapSet.member?(changed, &1.key))
        # A row another merge inserted since `before` was read: its old first finish is
        # not known here and is no later than now.
        olds = Enum.map(moved, &(before[&1.key] || %{first_finish: now}).first_finish)
        lo = moved |> Enum.map(& &1.finish) |> Enum.concat(olds) |> Enum.min(DateTime)
        hi = Enum.max(olds, DateTime)
        holders = for e <- moved, row = before[e.key], do: row.first_invocation_id

        overlapping =
          Repo.all(
            from(i in Invocation,
              where: i.project_id in ^project_ids and i.stream_actions > 0,
              where: i.started_at <= ^DateTime.add(hi, @margin_s, :second),
              where:
                coalesce(i.finished_at, i.last_event_at) >= ^DateTime.add(lo, -@margin_s, :second),
              select: i.id
            ),
            timeout: @timeout
          )

        Enum.uniq(holders ++ overlapping) -- [inv.id]
    end
  end

  defp rows(_scope, []), do: %{}

  defp rows(scope, keys) do
    keys
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from(k in ActionKey, where: k.scope == ^scope and k.key in ^chunk),
        timeout: @timeout
      )
    end)
    |> Map.new(&{&1.key, &1})
  end

  # --- an hour -------------------------------------------------------------------------------

  @doc """
  The stream half of an hour's report, for the finished builds `finished` selects; nil
  when none of them sent per-action events.

    * `"events"`: builds that sent them; `"builds"`: those reported here; `"logged"`:
      those reported from their execution log instead; `"pending"`: keys not merged yet;
      `"counts_only"`: reported, but without usable times; `"no_commit"`: timed, but
      without a commit (in no same-commit figure);
    * `"hit"`, `"untimed"`: `mnemonic → cell` of cache hits (the time is what the hit
      saved) and of actions without times;
    * `"any"`, `"same"`: `class → mnemonic → cell` of the executions against the any-commit
      key and against the same-commit key (classes as in `Conveyor.Rbe.Hour`; in `"same"`
      the executions of a build without a commit are `"nocommit"`);
    * `"est"`: the evidence for the estimate between the two (PLAN §28.4): `"xhit"`
      (`mnemonic → cell` of hits served from a build at another commit), `"diff"`
      (executions of a key although the build read the cache of the build that had
      finished it: the work changed) and `"unk"` (`class → mnemonic → cell` of the
      other executions that are duplicates at any commit only);
    * `"tgt"`: `project → target → space_class → [count, wall ms, core ms]` of the
      duplicates, for the #{@top} targets of the hour with the most.

  A cell is `[count, wall ms, core ms, 0, 0]` (no exact cores in a stream). Core time is
  wall × the CPU ÷ wall ratio of the mnemonic in the build (`BuildMetrics`; floor 1), or
  × 1 without one; the project's cores per mnemonic are applied when the report is read.
  """
  @spec hour(Ecto.Query.t()) :: map() | nil
  def hour(finished) do
    builds =
      Repo.all(
        from(i in subquery(finished),
          where: i.stream_actions > 0,
          order_by: i.id,
          select: map(i, [:id, :project_id, :tags, :exec_log_status, :stream_keys_at])
        ),
        timeout: @timeout
      )

    # A subquery's columns come back untyped.
    builds = Enum.map(builds, &%{&1 | id: uuid(&1.id)})
    {logged, rest} = Enum.split_with(builds, &(&1.exec_log_status in ["parsed", "expired"]))
    {used, pending} = Enum.split_with(rest, & &1.stream_keys_at)

    if builds == [] do
      nil
    else
      used
      |> Enum.reduce(%{}, &build/2)
      |> top_targets()
      |> cells_to_ms()
      |> Map.merge(%{
        "events" => length(builds),
        "builds" => length(used),
        "logged" => length(logged),
        "pending" => length(pending)
      })
    end
  end

  defp build(%{id: id, project_id: project_id, tags: tags}, acc) do
    records = records(id)
    {executions, others} = Enum.split_with(records, &StreamActions.execution?/1)
    commit = commit(tags)

    acc =
      Enum.reduce(others, acc, fn {_, _, duration, mnemonic, _, hit?, _}, acc ->
        add(acc, [if(hit?, do: "hit", else: "untimed"), mnemonic], [1, duration, duration])
      end)

    cond do
      not Enum.any?(records, &StreamActions.timed?/1) ->
        add(acc, ["counts_only"], 1)

      true ->
        acc = if commit, do: acc, else: add(acc, ["no_commit"], 1)
        [{own, _} | _] = scopes = project_id |> Projects.get_project!() |> Groups.scopes()
        {wide, _} = List.last(scopes)
        hits = Enum.filter(others, &StreamActions.linked_hit?/1)
        keys = Enum.map(executions, &elem(&1, 0))
        keys = if commit, do: keys ++ Enum.map(keys, &commit_key(&1, commit)), else: keys
        own_rows = rows(own, keys)

        wide_rows =
          if wide == own and hits == [],
            do: own_rows,
            else: rows(wide, Enum.uniq(keys ++ Enum.map(hits, &elem(&1, 0))))

        ratio = ratios(id, executions)
        {seen, acc} = seen(hits, id, commit, wide_rows, acc)
        pid = Integer.to_string(project_id)

        Enum.reduce(executions, acc, fn {key, start, duration, mnemonic, label, _, seq}, acc ->
          spawn = %{ordinal: seq, started_at: datetime(start)}
          class = &class(ActionKey.classify(spawn, id, own_rows[&1], wide_rows[&1]))
          cell = [1, duration, round(duration * Map.get(ratio, mnemonic, 1.0))]
          any = class.(key)
          same = if commit, do: class.(commit_key(key, commit)), else: "nocommit"

          acc
          |> add(["any", any, mnemonic], cell)
          |> add(["same", same, mnemonic], cell)
          |> estimate(any, same, wide_rows[key], seen, commit, mnemonic, cell)
          |> target(pid, label, any, same, cell)
        end)
    end
  end

  # The builds whose results this build read from a cache: a hit carries the start of the
  # execution it was served from, and that start is the first execution of its key in a
  # row held by another build. A hit served from a build at another commit (or with no
  # commit on either side) is counted under `"est" → "xhit"`: an action seen unchanged
  # across commits by a build that had the earlier result.
  defp seen([], _id, _commit, _rows, acc), do: {%{}, acc}

  defp seen(hits, id, commit, rows, acc) do
    linked =
      for {key, start, duration, mnemonic, _, _, _} <- hits,
          row = rows[key],
          row.first_invocation_id != id,
          row.first_start != nil,
          DateTime.to_unix(row.first_start, :microsecond) == start,
          do: {row.first_invocation_id, mnemonic, duration}

    seen = linked |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    commits =
      from(i in Invocation, where: i.id in ^seen, select: {i.id, i.tags})
      |> Repo.all(timeout: @timeout)
      |> Map.new(fn {id, tags} -> {id, commit(tags)} end)

    acc =
      Enum.reduce(linked, acc, fn {from, mnemonic, duration}, acc ->
        if commit == nil or commits[from] != commit,
          do: add(acc, ["est", "xhit", mnemonic], [1, duration, duration]),
          else: acc
      end)

    {commits, acc}
  end

  # The evidence for the estimate (PLAN §28.4). An execution that ran although its build
  # read the cache of the build that had finished its key, at another commit, says the
  # work changed between the two commits (`"diff"`, the counterpart of `"xhit"`). Such an
  # execution is no duplicate of that first one; any other execution that repeats its key
  # at any commit and is not a duplicate at its own commit is `"unk"`: nothing in the
  # stream says (kept by its any-commit class).
  defp estimate(acc, "first", _same, _row, _seen, _commit, _mnemonic, _cell), do: acc

  defp estimate(acc, any, same, row, seen, commit, mnemonic, cell) do
    from = row.first_invocation_id

    different? =
      any in ["seq", "seq_x"] and is_map_key(seen, from) and
        (commit == nil or seen[from] != commit)

    acc = if different?, do: add(acc, ["est", "diff", mnemonic], cell), else: acc

    if same in ["first", "nocommit"] and not different?,
      do: add(acc, ["est", "unk", any, mnemonic], cell),
      else: acc
  end

  # Per project and target: `[count, wall, core]` of the duplicates in either key space.
  defp target(acc, _pid, _label, "first", same, _cell) when same in ["first", "nocommit"],
    do: acc

  defp target(acc, pid, label, any, same, cell) do
    acc = if any == "first", do: acc, else: add(acc, ["tgt", pid, label, "any_" <> any], cell)

    if same in ["first", "nocommit"],
      do: acc,
      else: add(acc, ["tgt", pid, label, "same_" <> same], cell)
  end

  defp uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid(id), do: id

  defp class(:first), do: "first"
  defp class(:racing), do: "racing"
  defp class(:racing_cross), do: "racing_x"
  defp class(:sequential), do: "seq"
  defp class(:sequential_cross), do: "seq_x"

  # CPU time ÷ wall time per mnemonic of the build, where `BuildMetrics` has the CPU time.
  defp ratios(id, executions) do
    metrics = Repo.one(from m in Metrics, where: m.invocation_id == ^id, select: m.build_metrics)

    case Cores.cpu_ms(metrics) do
      cpu when cpu == %{} ->
        %{}

      cpu ->
        wall =
          Enum.reduce(executions, %{}, fn {_, _, duration, mnemonic, _, _, _}, acc ->
            Map.update(acc, mnemonic, duration, &(&1 + duration))
          end)

        for {mnemonic, us} <- wall, ms = cpu[mnemonic], into: %{} do
          {mnemonic, max(1.0, ms * 1000 / us)}
        end
    end
  end

  # The hour keeps the #{@top} targets with the most duplicated time (any commit).
  defp top_targets(%{"tgt" => by_project} = acc) do
    kept =
      for({pid, labels} <- by_project, {label, classes} <- labels, do: {pid, label, classes})
      |> Enum.sort_by(fn {pid, label, classes} ->
        {-(classes |> Map.values() |> Enum.map(&Enum.at(&1, 1)) |> Enum.sum()), pid, label}
      end)
      |> Enum.take(@top)
      |> Enum.reduce(%{}, fn {pid, label, classes}, acc -> add(acc, [pid, label], classes) end)

    Map.put(acc, "tgt", kept)
  end

  defp top_targets(acc), do: acc

  defp add(acc, [key], value), do: Map.update(acc, key, value, &Conveyor.Rbe.sum(&1, value))

  defp add(acc, [key | rest], value),
    do: Map.put(acc, key, add(Map.get(acc, key, %{}), rest, value))

  # Sums are kept in microseconds while an hour is computed; a stored cell is in
  # milliseconds like those of the execution log.
  defp cells_to_ms([n, us, core_us]) when is_integer(n),
    do: [n, round(us / 1000), round(core_us / 1000), 0, 0]

  defp cells_to_ms(%{"tgt" => _} = map) do
    {tgt, rest} = Map.pop(map, "tgt")
    Map.put(cells_to_ms(rest), "tgt", tgt_to_ms(tgt))
  end

  defp cells_to_ms(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, cells_to_ms(v)} end)
  defp cells_to_ms(n), do: n

  # A target's cells stay `[count, wall ms, core ms]`.
  defp tgt_to_ms([n, us, core_us]) when is_integer(n),
    do: [n, round(us / 1000), round(core_us / 1000)]

  defp tgt_to_ms(map), do: Map.new(map, fn {k, v} -> {k, tgt_to_ms(v)} end)

  @doc "An hour's stored report with its stream half (`\"stream\"`); nil when both are nil."
  @spec join(map() | nil, map() | nil) :: map() | nil
  def join(log, nil), do: log
  def join(log, stream), do: Map.put(log || %{}, "stream", stream)

  @doc "The two halves of a stored report: `{from execution logs, from the stream}`."
  @spec split(map() | nil) :: {map() | nil, map() | nil}
  def split(nil), do: {nil, nil}

  def split(rbe) do
    case Map.pop(rbe, "stream") do
      {stream, log} when log == %{} -> {nil, stream}
      {stream, log} -> {log, stream}
    end
  end

  # --- retention -----------------------------------------------------------------------------

  @doc """
  How many days a project's stream records are kept: its `row_days` (default 3, the
  setting of the analysis-only mode, whether or not that mode is on), at most the
  execution-log retention. Keys and hourly rows stay as for execution logs.
  """
  @spec days(Projects.Project.t()) :: pos_integer()
  def days(%Projects.Project{} = project),
    do: min(Settings.get(project).row_days, ExecLog.general_retention_days(project))

  @doc """
  True when the hour no longer takes stream numbers: its builds' records have expired or
  are within an hour of expiring (the freeze rule of PLAN §27.11).
  """
  @spec frozen?(Projects.Project.t() | integer(), DateTime.t()) :: boolean()
  def frozen?(project_id, hour) when is_integer(project_id),
    do: project_id |> Projects.get_project!() |> frozen?(hour)

  def frozen?(%Projects.Project{} = project, %DateTime{} = hour) do
    hour = %{hour | minute: 0, second: 0, microsecond: {0, 0}}
    limit = ExecLog.now() |> DateTime.add(-days(project), :day) |> DateTime.add(3600, :second)
    DateTime.compare(hour, limit) == :lt
  end

  @doc "Deletes the records of a project's builds that started before its cutoff."
  @spec expire!(Projects.Project.t(), DateTime.t()) :: non_neg_integer()
  def expire!(%Projects.Project{id: project_id} = project, now) do
    cutoff = DateTime.add(now, -days(project), :day)

    builds =
      from i in Invocation,
        where: i.project_id == ^project_id and i.stream_actions > 0 and i.started_at < ^cutoff,
        select: i.id

    {n, _} =
      Repo.delete_all(from(c in StreamChunk, where: c.invocation_id in subquery(builds)),
        timeout: @timeout
      )

    n
  end

  @doc "The projects with builds that sent per-action events since `since`."
  @spec projects(DateTime.t()) :: [integer()]
  def projects(since) do
    Repo.all(
      from(i in Invocation,
        where: i.stream_actions > 0 and i.started_at >= ^since,
        distinct: true,
        select: i.project_id
      ),
      timeout: @timeout
    )
  end
end
