defmodule Conveyor.Repo.Migrations.AddRawLogObjectColumns do
  use Ecto.Migration

  # PLAN §25 step 2: in blob mode a segment row carries no payload; it points at a byte
  # range of a raw-log object the writer wrote before committing the row. Both tables are
  # partitioned by day; altering the parent alters every partition.
  def change do
    execute(
      "ALTER TABLE event_segments ALTER COLUMN payload DROP NOT NULL",
      "ALTER TABLE event_segments ALTER COLUMN payload SET NOT NULL"
    )

    execute(
      "ALTER TABLE log_segments ALTER COLUMN data DROP NOT NULL",
      "ALTER TABLE log_segments ALTER COLUMN data SET NOT NULL"
    )

    for table <- [:event_segments, :log_segments] do
      alter table(table) do
        add :object_key, :text
        add :object_offset, :bigint
        add :object_length, :integer
      end
    end
  end
end
