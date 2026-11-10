defmodule Conveyor.Workers.ArchiveRaw do
  @moduledoc """
  Raw write-behind (`Conveyor.RawStore.compact_due/2`). The cron entry (every 15 minutes)
  compacts every build that is due, batch by batch, for at most nine minutes, and snoozes
  itself for a second when builds remain: the job stays the one job, so the next cron
  entry does not start a second run beside it. Runs on the `archive` queue so a backlog
  never delays partition maintenance, retention or rollups. Does nothing while
  `RAW_ARCHIVE_ENABLED` is off.

  With `%{"id" => id, "project_id" => project_id}` it compacts that one build: the jobs
  enqueued per build before 2026-11 (one per due build), and a way to compact a build by
  hand.
  """
  use Oban.Worker,
    queue: :archive,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:id], states: :incomplete]

  alias Conveyor.RawStore

  @deadline_ms :timer.minutes(9)

  # Below Lifeline's rescue window (docs/spec/Oban.tla, oban_rescue_test.exs).
  @impl Oban.Worker
  def timeout(_job), do: @deadline_ms + :timer.minutes(3)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => _} = args}) do
    if RawStore.compaction?(),
      do: RawStore.compact(build(args)),
      else: {:cancel, :disabled}
  end

  def perform(%Oban.Job{}) do
    if RawStore.compaction?() do
      case RawStore.compact_due(DateTime.utc_now(), opts()) do
        %{remaining?: true} -> {:snooze, 1}
        result -> {:ok, result}
      end
    else
      {:ok, :disabled}
    end
  end

  defp opts,
    do: Keyword.merge([deadline_ms: @deadline_ms], Application.get_env(:conveyor, __MODULE__, []))

  # The build inside the project the job was enqueued for; jobs enqueued before the
  # arguments carried the project are looked up by id alone.
  defp build(%{"id" => id, "project_id" => project_id}) when is_integer(project_id),
    do: Conveyor.Invocations.get(id, project_ids: [project_id]) || :gone

  defp build(%{"id" => id}), do: id
end
