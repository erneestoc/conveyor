defmodule Conveyor.Workers.RawLogSweep do
  @moduledoc """
  Deletes the raw-log objects no segment row can reference any more
  (`Conveyor.RawStore.expire_objects/2`; which objects those are is
  `Conveyor.RawStore.Expiry`'s rule 2), orphans of commits that failed after their put
  included. A no-op in postgres mode unless objects remain from a blob-mode period.

  Runs hourly, because blob mode writes objects all day (one per shard per second per
  node, more under flat-out load) and a daily run would have a day's worth to delete at
  once. A run deletes page after page for at most ten minutes, under Oban Lifeline's
  rescue window, and enqueues its own continuation when objects remain, so a backlog
  drains without waiting for the next hour.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

  @deadline_ms :timer.minutes(10)

  # Below Lifeline's rescue window (docs/spec/Oban.tla, oban_rescue_test.exs).
  @impl Oban.Worker
  def timeout(_job), do: @deadline_ms + :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    result = Conveyor.RawStore.expire_objects(as_of(args), opts())

    # The continuation carries a counter: its arguments differ from this job's, so the
    # uniqueness that keeps two nodes' cron entries from doubling up does not drop it.
    if result.remaining?,
      do: Oban.insert!(new(Map.put(args, "continued", Map.get(args, "continued", 0) + 1)))

    {:ok, result}
  end

  # `as_of` (ISO 8601) runs the sweep for another clock than the wall's: to rehearse what
  # a shorter retention would delete, and in tests.
  defp as_of(%{"as_of" => iso}) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    at
  end

  defp as_of(_args), do: DateTime.utc_now()

  defp opts,
    do: Keyword.merge([deadline_ms: @deadline_ms], Application.get_env(:conveyor, __MODULE__, []))
end
