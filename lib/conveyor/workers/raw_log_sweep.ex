defmodule Conveyor.Workers.RawLogSweep do
  @moduledoc """
  Deletes raw-log objects older than the raw retention plus a day (PLAN §25 step 2). After
  the partition drop no segment row can reference such an object, and an orphan left by a
  commit that failed after its put goes the same way. Runs daily; a no-op in postgres mode
  unless old objects remain from a blob-mode period.

  The cutoff never passes the day of the oldest segment partition that still exists: an
  object is registered when its batches commit, so a row in a partition of day `d` only
  ever references objects registered on or after `d`, and a partition kept past its date
  (a stalled maintenance queue, the raw archive's drop guard) keeps its objects too
  (`docs/spec/RawLog.tla`, the `current` configuration shows the race without this).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  alias Conveyor.Storage.Partitions

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:conveyor, :retention_raw_days, 14) + 1
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    cutoff =
      case Partitions.oldest_day() do
        nil -> cutoff
        day -> Enum.min([cutoff, DateTime.new!(day, ~T[00:00:00], "Etc/UTC")], DateTime)
      end

    {:ok, %{swept: Conveyor.RawLog.sweep(cutoff)}}
  end
end
