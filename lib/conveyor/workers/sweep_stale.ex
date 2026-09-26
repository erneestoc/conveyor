defmodule Conveyor.Workers.SweepStale do
  @moduledoc """
  Every ten minutes: builds left `in_progress` by a stream that no node serves any more (the
  node died mid-build and the client never came back) are marked `disconnected`, as the
  worker's own idle timeout would have done. A live worker changes its row with every
  commit and marks its build disconnected itself after one idle window, so a row unchanged
  for two idle windows has no worker (the rule `docs/spec/Retention.tla` relies on). One
  conditional statement per run: a commit landing meanwhile changes `updated_at` and the
  row no longer matches. A client that resumes later continues the build as it would
  after an idle timeout. `updated_at` moves, so the dashboard rollups see the new status.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

  import Ecto.Query

  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, %{swept: sweep()}}

  @doc "Marks stale in-progress builds disconnected; returns how many."
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    idle_ms = Conveyor.Ingest.config(:idle_timeout_ms, 600_000)
    stale = DateTime.add(now, -2 * idle_ms, :millisecond)

    {n, _} =
      Repo.update_all(
        from(i in Invocation,
          where: i.status == "in_progress" and i.updated_at < ^stale,
          update: [
            set: [
              status: "disconnected",
              finished_at:
                fragment("coalesce(?, ?, ?)", i.finished_at, i.last_event_at, i.updated_at),
              duration_ms:
                fragment(
                  "coalesce(?, (extract(epoch from (coalesce(?, ?) - ?)) * 1000)::bigint)",
                  i.duration_ms,
                  i.last_event_at,
                  i.updated_at,
                  i.started_at
                ),
              updated_at: ^now
            ]
          ]
        ),
        []
      )

    n
  end
end
