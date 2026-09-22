defmodule Conveyor.Workers.ParseExecLog do
  @moduledoc "Parses an uploaded execution log into spawns and notifies the invocation page."
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, keys: [:invocation_id]]

  alias Conveyor.{Artifacts, Blobs, ExecLog, Invocations}

  # Shorter than the Lifeline rescue window (15 min), so a parse that runs away fails with
  # an error and a retry instead of being "rescued" while still executing (which runs it
  # twice and burns its attempts: the trial's stalled jobs).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invocation_id" => id}}) do
    with %{} = inv <- Invocations.get(id) || {:cancel, :no_invocation},
         %{} = artifact <-
           Enum.find(Artifacts.list(inv), &ExecLog.name?(&1.name)) || {:cancel, :no_log},
         {:ok, binary} <- Blobs.read(inv.project_id, artifact.digest),
         {:ok, parsed} <- parse(inv, binary) do
      count = ExecLog.store!(inv, parsed)

      Phoenix.PubSub.broadcast(
        Conveyor.PubSub,
        Conveyor.Ingest.invocation_topic(inv.id),
        {:artifacts_changed, inv.id}
      )

      {:ok, count}
    else
      {:cancel, reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(inv, binary) do
    case ExecLog.parse(binary) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        ExecLog.set_status(inv, "failed")
        {:cancel, reason}
    end
  end
end
