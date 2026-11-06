defmodule Conveyor.Workers.RawLogSweep do
  @moduledoc """
  Deletes raw-log objects older than the raw retention plus a day (PLAN §25 step 2). After
  the partition drop no segment row can reference such an object, and an orphan left by a
  commit that failed after its put goes the same way. Runs daily; a no-op in postgres mode
  unless old objects remain from a blob-mode period.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:conveyor, :retention_raw_days, 14) + 1
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    {:ok, %{swept: Conveyor.RawLog.sweep(cutoff)}}
  end
end
