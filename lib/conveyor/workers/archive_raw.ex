defmodule Conveyor.Workers.ArchiveRaw do
  @moduledoc """
  Raw write-behind (`Conveyor.RawArchive`). Without arguments (cron, every 15 minutes) it
  enqueues one job per due build, unique per invocation while one is pending; with
  `%{"id" => id}` it archives that build. Runs on the `archive` queue so a backlog never
  delays partition maintenance, retention or rollups. Does nothing while
  `RAW_ARCHIVE_ENABLED` is off.
  """
  use Oban.Worker,
    queue: :archive,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:id], states: :incomplete]

  alias Conveyor.RawArchive

  # Below Lifeline's rescue window (docs/spec/Oban.tla, oban_rescue_test.exs).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    if RawArchive.enabled?() do
      case RawArchive.archive(id) do
        {:ok, outcome} -> {:ok, outcome}
        {:error, reason} -> {:error, reason}
      end
    else
      {:cancel, :disabled}
    end
  end

  def perform(%Oban.Job{}) do
    if RawArchive.enabled?() do
      ids = RawArchive.candidates()
      Enum.each(ids, &Oban.insert!(new(%{id: &1})))
      {:ok, %{enqueued: length(ids)}}
    else
      {:ok, :disabled}
    end
  end
end
