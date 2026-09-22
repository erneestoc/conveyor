defmodule Conveyor.Workers.Rollup do
  @moduledoc """
  Keeps `invocation_rollups` current: every few minutes the hours with builds started in
  the last two days whose rows are missing or stale are rolled again (PLAN §24 item 6);
  once a day everything inside the longest dashboard range is checked, which also
  backfills after a deploy.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 60]

  alias Conveyor.Metrics.Rollup

  @impl true
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "days", 2)
    written = Rollup.refresh!(DateTime.add(DateTime.utc_now(), -days * 86_400, :second))
    {:ok, written}
  end
end
