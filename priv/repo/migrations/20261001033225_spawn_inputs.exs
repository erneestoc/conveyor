defmodule Conveyor.Repo.Migrations.SpawnInputs do
  use Ecto.Migration

  @moduledoc """
  Execution-log input lists are stored once per `(project, digest)` in `spawn_inputs` and
  referenced by `spawns.inputs_digest` instead of being copied into every spawn row: on the
  AWS trial 79 % of the 48,030 lists were exact duplicates and held 96 % of the table
  (`docs/capacity.md`). Existing lists are moved over (one per distinct digest and project)
  and the column is dropped. The backfill scans every spawn once (minutes on a large
  table; migrations run without a statement timeout).
  """

  def up do
    create table(:spawn_inputs, primary_key: false) do
      add :project_id, references(:projects, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :digest, :string, null: false, primary_key: true
      add :blob, :binary, null: false
      # Refreshed whenever a store references the list: orphan pruning leaves young rows
      # alone (docs/spec/SpawnInputs.tla).
      add :touched_at, :utc_datetime_usec, null: false
    end

    execute("""
    INSERT INTO spawn_inputs (project_id, digest, blob, touched_at)
    SELECT DISTINCT ON (i.project_id, s.inputs_digest)
           i.project_id, s.inputs_digest, s.inputs_blob, now()
    FROM spawns s JOIN invocations i ON i.id = s.invocation_id
    WHERE s.inputs_blob IS NOT NULL AND s.inputs_digest IS NOT NULL
    ORDER BY i.project_id, s.inputs_digest, s.id
    """)

    alter table(:spawns) do
      remove :inputs_blob
    end
  end

  def down do
    alter table(:spawns) do
      add :inputs_blob, :binary
    end

    execute("""
    UPDATE spawns s SET inputs_blob = si.blob
    FROM spawn_inputs si JOIN invocations i ON i.project_id = si.project_id
    WHERE s.invocation_id = i.id AND s.inputs_digest = si.digest
    """)

    drop table(:spawn_inputs)
  end
end
