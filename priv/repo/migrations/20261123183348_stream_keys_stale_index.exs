defmodule Conveyor.Repo.Migrations.StreamKeysStaleIndex do
  use Ecto.Migration

  # PLAN §28.6: the builds whose stream keys are to be merged are those never merged
  # (`invocations_stream_keys_pending`, from 20261123173252) and those that received
  # events after their merge (a stream that came back). The second kind had no index, so
  # the job that looks for them every 5 minutes read every build of its window. Both
  # indexes hold only the rows that are waiting.
  def change do
    create index(:invocations, [:started_at],
             where: "stream_actions > 0 AND last_event_at > stream_keys_at",
             name: :invocations_stream_keys_stale
           )
  end
end
