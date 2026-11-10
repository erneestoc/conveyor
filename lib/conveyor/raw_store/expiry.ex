defmodule Conveyor.RawStore.Expiry do
  @moduledoc """
  When each form of a build's raw bytes may go: the date rules, stated once. They are
  pure functions of a clock and the configuration; `Conveyor.RawStore` asks them and the
  maintenance workers execute the answer (`RawStore.expire_partitions/1`,
  `expire_objects/2`, `compact_due/2`).

  With `R` = `RETENTION_RAW_DAYS` (default 14) and `H` = `RAW_ARCHIVE_AFTER_HOURS`
  (default 24):

    1. **Segment rows** live in daily partitions keyed by their build's creation day. The
       partition of day `d` may be dropped when `d < today − R` (`partition_cutoff/2`),
       *unless* compaction is on and the day still holds a finished build that is not
       compacted (`docs/spec/Archive.tla`, `DropGuard`: no arithmetic on `R` and `H`
       survives a store outage, so the drop looks instead of counting).
    2. **Raw-log objects** may be deleted once no segment row can point at them: registered
       before `now − (R + 1) days` *and* before 00:00 of the oldest segment partition that
       still exists (`object_cutoff/3`). An object is registered when its batches commit,
       never before their builds' creation day, so a partition of day `d` only references
       objects registered on or after `d`; a partition kept past its date (a stalled
       queue, rule 1's guard) keeps its objects (`docs/spec/RawLog.tla`: age alone is
       `RawLog_current.cfg`, which loses acknowledged bytes). This is also why an S3
       lifecycle rule on `rawlog/` is not a substitute: it knows the age and nothing else.
    3. **Compaction** is due for a build that finished more than `H` hours ago
       (`compaction_due_before/2`); only builds created on or after the oldest existing
       partition day are looked at, the others have no segments left
       (`compaction_window/3`). The server refuses to start with `R·24 < H + 24`
       (config/runtime.exs): a build would lose its partition before it is due.

  The archived blobs have no date rule of their own: they go when the build does (build
  retention deletes the row, `Conveyor.Blobs.prune_orphans/2` the blob nothing references).
  """

  @doc "`RETENTION_RAW_DAYS`: how long segment partitions are kept."
  @spec raw_days() :: pos_integer()
  def raw_days, do: Application.get_env(:conveyor, :retention_raw_days, 14)

  @doc "Rule 1: partitions of days strictly before this may be dropped."
  @spec partition_cutoff(Date.t(), pos_integer()) :: Date.t()
  def partition_cutoff(%Date{} = today, raw_days), do: Date.add(today, -raw_days)

  @doc """
  Rule 2: objects registered strictly before this may be deleted. `oldest_partition_day`
  is the day of the oldest segment partition that still exists, or nil when there is none.
  """
  @spec object_cutoff(DateTime.t(), pos_integer(), Date.t() | nil) :: DateTime.t()
  def object_cutoff(%DateTime{} = now, raw_days, oldest_partition_day) do
    by_age = DateTime.add(now, -(raw_days + 1), :day)

    case oldest_partition_day do
      nil -> by_age
      day -> Enum.min([by_age, start_of(day)], DateTime)
    end
  end

  @doc "Rule 3: a build that finished strictly before this is due for compaction."
  @spec compaction_due_before(DateTime.t(), pos_integer()) :: DateTime.t()
  def compaction_due_before(%DateTime{} = now, after_hours),
    do: DateTime.add(now, -after_hours * 3600, :second)

  @doc """
  Rule 3's search window over build creation times: from the oldest existing partition
  day to the due time, or nil when no partition exists (nothing has segments).
  """
  @spec compaction_window(DateTime.t(), pos_integer(), Date.t() | nil) ::
          {DateTime.t(), DateTime.t()} | nil
  def compaction_window(_now, _after_hours, nil), do: nil

  def compaction_window(%DateTime{} = now, after_hours, %Date{} = oldest_partition_day),
    do: {start_of(oldest_partition_day), compaction_due_before(now, after_hours)}

  @doc "The creation times a partition day covers: `[from, to)`."
  @spec day_span(Date.t()) :: {DateTime.t(), DateTime.t()}
  def day_span(%Date{} = day), do: {start_of(day), start_of(Date.add(day, 1))}

  defp start_of(%Date{} = day), do: DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
end
