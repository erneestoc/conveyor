defmodule Conveyor.Workers.StreamKeys do
  @moduledoc """
  Merges the keys of one build that sent per-action events as soon as it is final
  (`Conveyor.Rbe.Stream.merge_keys!/1`), so the Duplicate work page does not show it as
  "pending" until the next run of `Conveyor.Workers.Rollup` (every 5 minutes, which stays
  the backstop: a job lost here is merged there).

  One job per finalized stream, on the `parse` queue, so a node merges at most that
  queue's limit at once. No uniqueness check on insert (measured: the lookup cost more
  than the merge of a small build, PLAN §28.5): a second job for a build already merged
  since its last event returns at once, and the merge itself takes an advisory lock per
  build and merges minima, so a second node doing the same build, or the rollup job at
  the same moment, changes nothing. The merge makes the build's hour stale; the page's
  read path rolls stale hours, so nothing is rolled here.
  """
  use Oban.Worker, queue: :parse, max_attempts: 3

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
        if merged?(inv), do: :ok, else: Conveyor.Rbe.Stream.merge_keys!(inv)

      # Not final in the row (disconnected, or the row is behind): the rollup job's pass.
      _ ->
        {:cancel, :not_finished}
    end
  end

  defp merged?(%Invocation{stream_keys_at: nil}), do: false
  defp merged?(%Invocation{last_event_at: nil}), do: true

  defp merged?(%Invocation{stream_keys_at: at, last_event_at: last}),
    do: DateTime.compare(at, last) != :lt
end
