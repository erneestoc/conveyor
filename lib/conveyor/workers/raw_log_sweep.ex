defmodule Conveyor.Workers.RawLogSweep do
  @moduledoc """
  Deletes raw-log objects older than the raw retention plus a day (PLAN §25 step 2). After
  the partition drop no segment row can reference such an object, and an orphan left by a
  commit that failed after its put goes the same way. A no-op in postgres mode unless old
  objects remain from a blob-mode period.

  Runs hourly, because blob mode writes objects all day (one per shard per second per
  node, more under flat-out load) and a daily run would have a day's worth to delete at
  once. A run deletes page after page (`Conveyor.RawLog.sweep/2`) for at most ten minutes,
  under Oban Lifeline's rescue window, and enqueues its own continuation when objects
  remain, so a backlog drains without waiting for the next hour.

  The cutoff never passes the day of the oldest segment partition that still exists: an
  object is registered when its batches commit, so a row in a partition of day `d` only
  ever references objects registered on or after `d`, and a partition kept past its date
  (a stalled maintenance queue, the raw archive's drop guard) keeps its objects too
  (`docs/spec/RawLog.tla`, the `current` configuration shows the race without this).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

  alias Conveyor.Storage.Partitions

  @deadline_ms :timer.minutes(10)

  # Below Lifeline's rescue window (docs/spec/Oban.tla, oban_rescue_test.exs).
  @impl Oban.Worker
  def timeout(_job), do: @deadline_ms + :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    result = Conveyor.RawLog.sweep(cutoff(), sweep_opts())

    # The continuation carries a counter: its arguments differ from this job's, so the
    # uniqueness that keeps two nodes' cron entries from doubling up does not drop it.
    if result.remaining?,
      do: Oban.insert!(new(%{continued: Map.get(args, "continued", 0) + 1}))

    {:ok, result}
  end

  @doc "Registered before this, an object can no longer be referenced by any segment row."
  @spec cutoff(DateTime.t()) :: DateTime.t()
  def cutoff(now \\ DateTime.utc_now()) do
    days = Application.get_env(:conveyor, :retention_raw_days, 14) + 1
    by_age = DateTime.add(now, -days, :day)

    case Partitions.oldest_day() do
      nil -> by_age
      day -> Enum.min([by_age, DateTime.new!(day, ~T[00:00:00], "Etc/UTC")], DateTime)
    end
  end

  defp sweep_opts,
    do: Keyword.merge([deadline_ms: @deadline_ms], Application.get_env(:conveyor, __MODULE__, []))
end
