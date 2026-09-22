defmodule Conveyor.Workers.ProfileSummary do
  @moduledoc "Summarizes an available JSON profile into `invocation_metrics.profile_summary`."
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 60, keys: [:invocation_id]]

  alias Conveyor.{Blobs, Invocations, Profile, Repo}
  alias Conveyor.Invocations.Metrics

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invocation_id" => id}}) do
    with %{profile_blob: digest} = inv when is_binary(digest) <-
           Invocations.get(id) || {:cancel, :no_invocation},
         {:ok, chunks} <- Blobs.stream(inv.project_id, digest) do
      summary = chunks |> Profile.events() |> Profile.summarize()
      now = DateTime.utc_now()

      Repo.insert_all(
        Metrics,
        [%{invocation_id: inv.id, profile_summary: summary, inserted_at: now, updated_at: now}],
        on_conflict: {:replace, [:profile_summary, :updated_at]},
        conflict_target: :invocation_id
      )

      Phoenix.PubSub.broadcast(
        Conveyor.PubSub,
        Conveyor.Ingest.invocation_topic(inv.id),
        {:artifacts_changed, inv.id}
      )

      :ok
    else
      {:cancel, reason} -> {:cancel, reason}
      %{} -> {:cancel, :no_profile}
      {:error, :not_found} -> {:cancel, :blob_missing}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [Jason.DecodeError, ErlangError, MatchError] ->
      {:cancel, {:malformed_profile, Exception.message(e)}}
  end
end
