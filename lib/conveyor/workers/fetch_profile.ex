defmodule Conveyor.Workers.FetchProfile do
  @moduledoc "Fetches a finished build's JSON profile from its remote cache into the blob store."
  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: 60, keys: [:invocation_id]]

  alias Conveyor.Artifacts
  alias Conveyor.Invocations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invocation_id" => id}}) do
    case Invocations.get(id) do
      nil -> {:cancel, :no_invocation}
      %{profile_status: "available"} -> :ok
      inv -> finish(Artifacts.fetch_profile(inv))
    end
  end

  defp finish(:ok), do: :ok
  defp finish({:unavailable, reason}), do: {:cancel, reason}
  defp finish({:error, reason}), do: {:error, reason}
end
