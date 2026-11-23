defmodule Conveyor.Workers.Rollup do
  @moduledoc """
  Keeps `invocation_rollups` current: every few minutes the hours with builds started in
  the last two days whose rows are missing or stale are rolled again (PLAN §24 item 6);
  once a day everything inside the longest dashboard range is checked, which also
  backfills after a deploy.

  Projects that keep spawn rows for a few days only (`Conveyor.Rbe.Settings`,
  `analysis_only`) have their whole row window checked every time: an hour freezes when
  its rows are about to expire, and what its row holds then is final, so a log parsed up
  to one run of this job before the freeze must be in it (PLAN §27.11).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 60]

  alias Conveyor.Metrics.Rollup

  @impl true
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "days", 2)
    now = DateTime.utc_now()
    written = Rollup.refresh!(DateTime.add(now, -days * 86_400, :second))

    short =
      for project <- Conveyor.Projects.list_projects(),
          settings = Conveyor.Rbe.Settings.get(project),
          settings.analysis_only and settings.row_days >= days,
          do: {project.id, settings.row_days}

    more =
      case short do
        [] ->
          0

        short ->
          longest = short |> Enum.map(&elem(&1, 1)) |> Enum.max()

          Rollup.refresh!(
            DateTime.add(now, -(longest + 1) * 86_400, :second),
            Enum.map(short, &elem(&1, 0))
          )
      end

    {:ok, written + more}
  end
end
