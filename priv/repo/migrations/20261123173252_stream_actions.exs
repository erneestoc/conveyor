defmodule Conveyor.Repo.Migrations.StreamActions do
  use Ecto.Migration

  # PLAN §28: duplicate work from the event stream. One compact record per successful
  # `ActionExecuted` event, stored in chunks: a row per ingest batch that held such events
  # (never a row per action), written in the batch's fenced transaction. Rows live a few
  # days (the project's `row_days`); what stays is `action_keys` and the hourly sums.
  def change do
    create table(:stream_actions, primary_key: false) do
      add :invocation_id, :uuid, null: false, primary_key: true
      add :first_seq, :bigint, null: false, primary_key: true
      add :day, :date, null: false
      add :n, :integer, null: false
      add :records, :binary, null: false
    end

    create index(:stream_actions, [:day])

    alter table(:invocations) do
      # Successful per-action events received (a counter of the ingest path).
      add :stream_actions, :bigint, null: false, default: 0
      # When the build's stream keys were merged into `action_keys` (null: not yet).
      add :stream_keys_at, :utc_datetime_usec
    end

    create index(:invocations, [:project_id, :started_at],
             where: "stream_actions > 0 AND stream_keys_at IS NULL",
             name: :invocations_stream_keys_pending
           )
  end
end
