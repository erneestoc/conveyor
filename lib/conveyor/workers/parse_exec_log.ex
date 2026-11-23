defmodule Conveyor.Workers.ParseExecLog do
  @moduledoc "Parses an uploaded execution log into spawns and notifies the invocation page."
  use Oban.Worker,
    queue: :parse,
    max_attempts: 5,
    unique: [period: 60, keys: [:invocation_id]]

  alias Conveyor.{Artifacts, Blobs, ExecLog, Invocations}

  # Shorter than the Lifeline rescue window (15 min), so a parse that runs away fails with
  # an error and a retry instead of being "rescued" while still executing (which runs it
  # twice and burns its attempts: the trial's stalled jobs).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invocation_id" => _} = args}) do
    with %{} = inv <- Invocations.for_job(args) || {:cancel, :no_invocation},
         %{} = artifact <-
           Enum.find(Artifacts.list(inv), &ExecLog.name?(&1.name)) || {:cancel, :no_log},
         {:ok, binary} <- Blobs.read(inv.project_id, artifact.digest),
         settings = settings(inv),
         {:ok, parsed} <- parse(inv, binary, settings) do
      count = ExecLog.store!(inv, parsed)
      if settings.analysis_only, do: analysis_only(inv, artifact)

      Conveyor.Watch.broadcast(
        Conveyor.Ingest.invocation_topic(inv.id),
        {:artifacts_changed, inv.id}
      )

      {:ok, count}
    else
      {:cancel, reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settings(inv),
    do: inv.project_id |> Conveyor.Projects.get_project!() |> Conveyor.Rbe.Settings.get()

  # "Keep only what the duplicate-work metrics need": the uploaded log has been read for
  # the last time, so it goes (a failure before this point retries the whole job with the
  # log still there). A log whose build's hour is already frozen is counted as late: its
  # keys were merged, its executions are in no number (PLAN §27.11).
  defp analysis_only(inv, artifact) do
    Artifacts.delete(inv, artifact)

    if ExecLog.frozen?(inv.project_id, inv.started_at || inv.inserted_at),
      do: Conveyor.Rbe.Settings.count_late!(inv.project_id)
  end

  defp parse(inv, binary, settings) do
    # How the project declares cores is read here, at parse time: the cores an exec
    # property states are stored per spawn (PLAN §27.7).
    opts = [cores_property: settings.cores_property, analysis_only: settings.analysis_only]

    case ExecLog.parse(binary, opts) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        ExecLog.set_status(inv, "failed")
        {:cancel, reason}
    end
  end
end
