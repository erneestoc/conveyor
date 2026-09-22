defmodule Conveyor.Repo.Migrations.ProjectBlobs do
  use Ecto.Migration

  @moduledoc """
  Blobs become per project: the key is `(project_id, digest)` and every row records the
  key prefix its bytes were stored under (`NULL` = the original flat layout, so existing
  blobs stay readable). Existing rows are assigned to the default project.
  """

  def up do
    execute """
    INSERT INTO projects (slug, name, settings, inserted_at, updated_at)
    SELECT 'default', 'Default', '{}', now(), now()
    WHERE NOT EXISTS (SELECT 1 FROM projects WHERE slug = 'default')
    """

    alter table(:blobs) do
      add :project_id, references(:projects, on_delete: :delete_all)
      add :prefix, :string
    end

    execute "UPDATE blobs SET project_id = (SELECT id FROM projects WHERE slug = 'default')"

    alter table(:blobs) do
      modify :project_id, :bigint, null: false
    end

    execute "ALTER TABLE blobs DROP CONSTRAINT blobs_pkey"
    execute "ALTER TABLE blobs ADD PRIMARY KEY (project_id, digest)"

    # Orphan pruning anti-joins on the profile reference.
    create index(:invocations, [:profile_blob], where: "profile_blob IS NOT NULL")
  end

  def down do
    drop index(:invocations, [:profile_blob])
    execute "ALTER TABLE blobs DROP CONSTRAINT blobs_pkey"

    execute "DELETE FROM blobs b USING blobs o WHERE b.digest = o.digest AND b.project_id > o.project_id"

    execute "ALTER TABLE blobs ADD PRIMARY KEY (digest)"

    alter table(:blobs) do
      remove :project_id
      remove :prefix
    end
  end
end
