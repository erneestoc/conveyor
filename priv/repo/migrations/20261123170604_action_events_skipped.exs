defmodule Conveyor.Repo.Migrations.ActionEventsSkipped do
  use Ecto.Migration

  # PLAN §28.1: with `--build_event_publish_all_actions` a build sends one ActionExecuted
  # event (and one empty Progress event) per action. By default those frames are
  # acknowledged but not kept in the raw store. The sequence numbers they used are
  # accounted for: `invocations.events_skipped` counts them per build, and every event
  # segment says how many of them lie below its last sequence number, so the oracle can
  # still tell a dropped frame from a lost one.
  def change do
    alter table(:invocations) do
      add :events_skipped, :bigint, null: false, default: 0
    end

    alter table(:event_segments) do
      add :skipped_total, :bigint, null: false, default: 0
    end
  end
end
