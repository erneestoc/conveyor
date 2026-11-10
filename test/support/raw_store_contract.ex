defmodule Conveyor.RawStoreContract do
  @moduledoc """
  The contract of `Conveyor.RawStore`, as scenarios a test module runs against a store
  configuration (an adapter, a write mode): **the bytes appended are the bytes read**, in
  every form the store keeps them in and across every transition between forms.

  The helpers play the commit pipeline at the store's interface: build the segment rows,
  prepare and append a group, write the rows the store returns (what
  `Writer.Transaction` does) and keep the build's row in step. Time is never rewritten in
  the database: transitions that depend on a date are driven by the clock handed to the
  store (`compact/2`, `expire_partitions/1`, `expire_objects/2`).
  """
  import ExUnit.Assertions
  import Ecto.Query

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Invocations
  alias Conveyor.Invocations.{EventSegment, Invocation, LogSegment}
  alias Conveyor.{RawStore, Repo}
  alias Conveyor.Storage.Partitions

  @type build :: %{inv: Invocation.t(), messages: [binary()], log: binary()}

  # --- configuration ----------------------------------------------------------------------

  @doc "Switches the object store's adapter for the rest of the test (same directory)."
  def adapter!(Conveyor.Blobs.Disk), do: :ok

  def adapter!(module) do
    previous = Application.get_env(:conveyor, Conveyor.Blobs)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:conveyor, Conveyor.Blobs, previous) end)
    Application.put_env(:conveyor, Conveyor.Blobs, adapter: module, opts: [dir: previous[:dir]])
  end

  @doc "Turns compaction on or off for the rest of the test."
  def compaction!(enabled?) do
    previous = Application.get_env(:conveyor, Conveyor.RawArchive)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:conveyor, Conveyor.RawArchive, previous)
    end)

    Application.put_env(:conveyor, Conveyor.RawArchive, enabled: enabled?, after_hours: 24)
  end

  @doc "`RETENTION_RAW_DAYS` as configured."
  def raw_days, do: Application.get_env(:conveyor, :retention_raw_days, 14)

  # --- playing the pipeline ---------------------------------------------------------------

  @doc "A build that has started (its row exists, nothing appended), created at `at`."
  @spec build!(Conveyor.Projects.Project.t(), DateTime.t()) :: build()
  def build!(project, at \\ DateTime.utc_now()) do
    Partitions.ensure_day(DateTime.to_date(at))

    inv =
      Repo.insert!(%Invocation{
        id: Replay.uuid(),
        project_id: project.id,
        status: "in_progress",
        started_at: at,
        inserted_at: at,
        updated_at: at
      })

    %{inv: inv, messages: [], log: ""}
  end

  @doc """
  Lays out one group commit: `units` is a list of `{build, messages, log_text}` (either
  may be empty), in the order the group holds them.
  """
  def prepare(units, mode, shard \\ "contract") do
    %{bep: bep, text: text} = RawStore.compressors()

    rows =
      for {%{inv: inv, messages: before, log: log_before}, messages, log} <- units do
        unit = %{invocation_id: inv.id, day: Invocations.day(inv)}
        first = length(before) + 1

        events =
          messages |> Enum.with_index(first) |> Enum.map(fn {m, seq} -> {seq, "kind", m} end)

        bytes = messages |> Enum.map(&byte_size/1) |> Enum.sum()

        log_unit =
          Map.merge(unit, %{
            byte_offset: byte_size(log_before),
            line_offset: lines(log_before),
            bytes: byte_size(log),
            lines: lines(log)
          })

        chunks = if log == "", do: [], else: [{first + max(length(messages) - 1, 0), log}]

        {RawStore.event_segment(Map.put(unit, :bytes, bytes), events, bep),
         RawStore.log_segment(log_unit, chunks, text)}
      end

    %{append: RawStore.prepare(rows, shard, mode), units: units}
  end

  defp lines(text), do: text |> :binary.matches("\n") |> length()

  @doc """
  Appends a prepared group and commits its rows: `{:ok, builds}` (the builds as they are
  now, in unit order) or the store's `{:error, message}`, in which case nothing was
  written and the same prepared group may be committed again.
  """
  def commit(%{append: append, units: units}) do
    with {:ok, rows} <- RawStore.append(append) do
      events = for {row, _} <- rows, row != nil, do: row
      logs = for {_, row} <- rows, row != nil, do: row
      if events != [], do: Repo.insert_all(EventSegment, events, on_conflict: :nothing)
      if logs != [], do: Repo.insert_all(LogSegment, logs, on_conflict: :nothing)

      {:ok,
       for {build, messages, log} <- units do
         messages = build.messages ++ messages
         log = build.log <> log

         Repo.update_all(from(i in Invocation, where: i.id == ^build.inv.id),
           set: [
             event_count: length(messages),
             last_event_seq: length(messages),
             log_bytes: byte_size(log),
             log_lines: lines(log)
           ]
         )

         %{inv: Repo.get!(Invocation, build.inv.id), messages: messages, log: log}
       end}
    end
  end

  @doc "`prepare/3` and `commit/1`, for a group that must succeed."
  def append!(units, mode, shard \\ "contract") do
    {:ok, builds} = units |> prepare(mode, shard) |> commit()
    builds
  end

  @doc "The build's stream ends at `at`: the marker's sequence number, the final status."
  def finish!(%{inv: inv} = build, at \\ DateTime.utc_now()) do
    Repo.update_all(from(i in Invocation, where: i.id == ^inv.id),
      set: [
        status: "succeeded",
        stream_finished: true,
        finished_at: at,
        last_event_seq: length(build.messages) + 1
      ]
    )

    reload(build)
  end

  def reload(%{inv: inv} = build), do: %{build | inv: Repo.get!(Invocation, inv.id)}

  @doc "A group in each of the given modes for two builds that share every group, then both finish."
  def two_builds!(project, modes) do
    a = build!(project)
    b = build!(project)
    big = :crypto.strong_rand_bytes(70_000)

    groups = [
      fn a, b -> [{a, ["a1", "", "a3"], "first line\nsecond "}, {b, ["b1", "b2"], ""}] end,
      fn a, b -> [{b, [], "b logs before its next event\n"}, {a, [big], "line\n"}] end,
      fn a, b ->
        [{a, ["a5", "a6"], ""}, {b, ["b3", "b4", "b5", big], "tail without newline"}]
      end,
      fn a, b -> [{a, [], "the end\n"}, {b, [], ""}] end
    ]

    {a, b} =
      groups
      |> Enum.zip(Stream.cycle(modes))
      |> Enum.reduce({a, b}, fn {group, mode}, {a, b} ->
        builds = append!(group.(a, b), mode)
        {Enum.find(builds, &(&1.inv.id == a.inv.id)), Enum.find(builds, &(&1.inv.id == b.inv.id))}
      end)

    # The same instant for both: whoever pages through due builds must break the tie.
    at = DateTime.utc_now()
    {finish!(a, at), finish!(b, at)}
  end

  # --- what a reader sees -----------------------------------------------------------------

  @pages [{1, 1}, {2, 1}, {1, 4}, {2, 4}, {3, 4}, {1, 1000}, {2, 1000}]

  @doc "Everything the store's readers return for a build, streams read to the end."
  def reads(%Invocation{} = inv) do
    log = RawStore.log(inv)

    %{
      frames: RawStore.frames(inv),
      bep: inv |> RawStore.bep() |> Enum.to_list() |> IO.iodata_to_binary(),
      log_bytes: log.bytes,
      log: log.chunks |> Enum.to_list() |> IO.iodata_to_binary(),
      pages: for({page, per} <- @pages, do: RawStore.events_page(inv, page, per)),
      audit: RawStore.audit(inv)
    }
  end

  @doc "What the readers must return for what was appended."
  def expected(%{messages: messages, log: log}) do
    n = length(messages)
    numbered = Enum.with_index(messages, 1) |> Enum.map(fn {m, i} -> {i, m} end)

    %{
      frames: messages,
      bep:
        messages
        |> Enum.map(&[Fixture.encode_varint(byte_size(&1)), &1])
        |> IO.iodata_to_binary(),
      log_bytes: byte_size(log),
      log: log,
      pages: for({page, per} <- @pages, do: {Enum.slice(numbered, (page - 1) * per, per), n}),
      audit: %{frames: n, events: n, log_bytes: byte_size(log), problems: []}
    }
  end

  @doc "Asserts that every reader returns exactly what was appended to the build."
  def assert_reads!(%{inv: %Invocation{id: id}} = build) do
    inv = Repo.get!(Invocation, id)
    got = reads(inv)
    want = expected(build)
    for key <- Map.keys(want), do: assert(got[key] == want[key], "#{key} differs for build #{id}")
    inv
  end

  @doc "Asserts that the build's raw bytes are gone (retention), read as empty, not as an error."
  def assert_expired!(%{inv: %Invocation{id: id}}) do
    inv = Repo.get!(Invocation, id)
    assert RawStore.frames(inv) == []
    assert %{bytes: 0, chunks: chunks} = RawStore.log(inv)
    assert Enum.to_list(chunks) == []
    assert {[], 0} = RawStore.events_page(inv, 1, 10)
  end

  # --- scenarios --------------------------------------------------------------------------

  defp partition(table, day), do: "#{table}_#{Calendar.strftime(day, "%Y%m%d")}"

  # Every group of `two_builds!/2` holds bytes: one object per group appended in blob mode.
  defp objects(modes), do: modes |> Stream.cycle() |> Enum.take(4) |> Enum.count(&(&1 == :blob))

  @doc """
  Payload or range → archived, with compaction on: reads are identical before and after
  compaction, after the segment partition is dropped and after the raw-log objects are
  deleted; the drop and the sweep wait for compaction; build retention frees the blobs.
  """
  def lifecycle!(project, modes) do
    compaction!(true)
    {a, b} = two_builds!(project, modes)
    now = DateTime.utc_now()
    today = DateTime.to_date(a.inv.inserted_at)
    past_retention = Date.add(Date.utc_today(), raw_days() + 1)
    sweep_clock = DateTime.add(now, (raw_days() + 2) * 86_400, :second)
    later = DateTime.add(now, 2, :day)
    before = assert_reads!(a)
    assert_reads!(b)

    # Not due yet: the builds finished a moment ago.
    assert {:ok, :not_due} = RawStore.compact(a.inv.id, now)

    assert %{archived: 0, skipped: 0, lost: 0, failed: 0, remaining?: false} =
             RawStore.compact_due(now)

    # Past raw retention the day stays, and its objects with it: finished builds on it
    # are not compacted (Archive.tla DropGuard; RawLog.tla, the oldest-partition bound).
    dropped = RawStore.expire_partitions(past_retention)
    refute partition("event_segments", today) in dropped
    refute partition("log_segments", today) in dropped
    assert %{deleted: 0, failed: 0} = RawStore.expire_objects(sweep_clock)
    assert_reads!(a)

    # A day later both are due; compacting one of them is not enough to free the day.
    assert RawStore.compaction_overdue_seconds(later) > 0
    assert {:ok, :archived} = RawStore.compact(a.inv.id, later)
    archived = assert_reads!(a)
    assert archived.updated_at == before.updated_at
    assert {:ok, :already_archived} = RawStore.compact(a.inv.id, later)
    refute partition("event_segments", today) in RawStore.expire_partitions(past_retention)

    # A run compacts what is left that is due, and then nothing is.
    assert %{archived: 1, failed: 0, remaining?: false} = RawStore.compact_due(later)
    assert %{archived: 0} = RawStore.compact_due(later)
    assert_reads!(b)

    # Now the day goes, then the objects; the builds read the same from their blobs.
    dropped = RawStore.expire_partitions(past_retention)
    assert partition("event_segments", today) in dropped
    assert partition("log_segments", today) in dropped
    assert_reads!(a)
    assert_reads!(b)

    assert %{objects: backlog} = RawStore.expiry_backlog(sweep_clock)
    assert backlog == objects(modes)

    assert %{deleted: ^backlog, failed: 0, remaining?: false} =
             RawStore.expire_objects(sweep_clock)

    assert %{objects: 0, overdue_seconds: 0} = RawStore.expiry_backlog(sweep_clock)
    assert_reads!(a)
    assert_reads!(b)

    # Build retention deletes the rows; the blobs are orphans once the grace has passed.
    blobs = Repo.aggregate(from(x in Conveyor.Blobs.Blob, where: x.source == "raw"), :count)
    Repo.delete_all(from i in Invocation, where: i.id in ^[a.inv.id, b.inv.id])
    assert Conveyor.Blobs.prune_orphans(DateTime.add(now, 2, :hour)) == blobs
    assert Repo.aggregate(from(x in Conveyor.Blobs.Blob, where: x.source == "raw"), :count) == 0
    :ok
  end

  @doc """
  Without compaction the hot forms go by the clock alone: nothing before raw retention has
  passed, the partition the day after, the objects only once the partition is gone.
  """
  def hot_expiry!(project, modes) do
    compaction!(false)
    {a, b} = two_builds!(project, modes)
    now = DateTime.utc_now()
    today = DateTime.to_date(a.inv.inserted_at)
    days = raw_days()

    # On the last day of retention nothing goes.
    refute partition("event_segments", today) in RawStore.expire_partitions(Date.add(today, days))
    assert %{deleted: 0} = RawStore.expire_objects(DateTime.add(now, days * 86_400, :second))
    assert_reads!(a)

    # A sweep that runs before the partition drop (the drop is late, or stalled) deletes
    # nothing, however late it is itself: a row may still point at the objects.
    assert %{deleted: 0} = RawStore.expire_objects(DateTime.add(now, 40 * 86_400, :second))
    assert_reads!(a)
    assert_reads!(b)

    # The day after, the partition goes: the builds' raw bytes are past retention.
    dropped = RawStore.expire_partitions(Date.add(today, days + 1))
    assert partition("event_segments", today) in dropped
    assert partition("log_segments", today) in dropped
    assert_expired!(a)
    assert_expired!(b)

    # And only then the objects.
    clock = DateTime.add(now, (days + 2) * 86_400, :second)
    count = objects(modes)
    assert %{objects: ^count} = RawStore.expiry_backlog(clock)
    assert %{deleted: ^count, failed: 0, remaining?: false} = RawStore.expire_objects(clock)
    assert %{deleted: 0} = RawStore.expire_objects(clock)
    :ok
  end
end
