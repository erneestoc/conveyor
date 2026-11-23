defmodule Conveyor.Workers.StreamKeys do
  @moduledoc """
  Merges the keys of one build that sent per-action events as soon as it is final
  (`Conveyor.Rbe.Stream.merge_keys!/1`), so the Duplicate work page does not show it as
  "pending" until the next run of `Conveyor.Workers.Rollup` (every 5 minutes, which stays
  the backstop: a job lost here is merged there).

  One job per build (unique by its id), on the `parse` queue, so a node merges at most
  that queue's limit at once. The merge takes an advisory lock per build and merges
  minima, so a second node doing the same build, or the rollup job at the same moment,
  changes nothing. The merge makes the build's hour stale; the page's read path rolls
  stale hours, so nothing is rolled here.
  """
  use Oban.Worker,
    queue: :parse,
    max_attempts: 3,
    unique: [period: 300, keys: [:invocation_id]]

  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo

  @finished ["succeeded", "failed", "aborted"]

  @doc "Schedules the merge of a build; never raises into the ingest path."
  @spec enqueue(String.t()) :: :ok
  def enqueue(invocation_id) when is_binary(invocation_id) do
    if Application.get_env(:conveyor, :stream_keys_on_finalize, true) do
      %{invocation_id: invocation_id} |> new() |> Oban.insert()
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invocation_id" => id}}) do
    case Repo.get(Invocation, id) do
      %Invocation{status: status, stream_actions: n} = inv when status in @finished and n > 0 ->
        Conveyor.Rbe.Stream.merge_keys!(inv)

      # Not final in the row (disconnected, or the row is behind): the rollup job's pass.
      _ ->
        {:cancel, :not_finished}
    end
  end
end
