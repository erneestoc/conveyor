defmodule Conveyor.Workers.ArchiveRaw do
  @moduledoc """
  Raw write-behind (`Conveyor.RawStore.compact/2`). Without arguments (cron, every 15 minutes) it
  enqueues one job per due build (all of them, page by page), unique per invocation while one is pending; with
  `%{"id" => id, "project_id" => project_id}` it archives that build. Runs on the `archive` queue so a backlog never
  delays partition maintenance, retention or rollups. Does nothing while
  `RAW_ARCHIVE_ENABLED` is off.
  """
  use Oban.Worker,
    queue: :archive,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:id], states: :incomplete]

  alias Conveyor.RawStore

  # Below Lifeline's rescue window (docs/spec/Oban.tla, oban_rescue_test.exs).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => _} = args}) do
    if RawStore.compaction?() do
      RawStore.compact(build(args))
    else
      {:cancel, :disabled}
    end
  end

  def perform(%Oban.Job{}) do
    if RawStore.compaction?() do
      due = RawStore.due_for_compaction()

      Enum.each(due, fn {id, project_id} ->
        Oban.insert!(new(%{id: id, project_id: project_id}))
      end)

      {:ok, %{enqueued: length(due)}}
    else
      {:ok, :disabled}
    end
  end

  # The build inside the project the job was enqueued for; jobs enqueued before the
  # arguments carried the project are looked up by id alone (`RawStore.compact/2`).
  defp build(%{"id" => id, "project_id" => project_id}) when is_integer(project_id),
    do: Conveyor.Invocations.get(id, project_ids: [project_id]) || :gone

  defp build(%{"id" => id}), do: id
end
