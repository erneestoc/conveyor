defmodule Conveyor.Repo.Migrations.ProjectBlobs do
  use Ecto.Migration

  @moduledoc """
  Blobs become per project: the key is `(project_id, digest)` and every row records the
  key prefix its bytes were stored under (`NULL` = the original flat layout, so existing
  blobs stay readable). Existing rows are assigned to the projects that reference them
  (one row per referencing project: artifacts of the project's invocations and profiles),
  and unreferenced ones (CAS uploads still within their TTL) to the default project.
  Rows copied this way share one physical object; `Conveyor.Blobs` only deletes a flat
  object when no other row still points at it.
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

    execute "ALTER TABLE blobs DROP CONSTRAINT blobs_pkey"

    # One row per project that references the digest.
    execute """
    INSERT INTO blobs (project_id, digest, prefix, size, content_type, storage, source,
                       expires_at, last_used_at, inserted_at)
    SELECT DISTINCT ON (r.project_id, b.digest)
           r.project_id, b.digest, NULL, b.size, b.content_type, b.storage, b.source,
           b.expires_at, b.last_used_at, b.inserted_at
    FROM blobs b
    JOIN (
      SELECT i.project_id, a.digest
      FROM invocation_artifacts a JOIN invocations i ON i.id = a.invocation_id
      UNION
      SELECT i.project_id, i.profile_blob FROM invocations i WHERE i.profile_blob IS NOT NULL
    ) r ON r.digest = b.digest
    WHERE b.project_id IS NULL
    """

    execute """
    DELETE FROM blobs b
    WHERE b.project_id IS NULL
      AND EXISTS (SELECT 1 FROM blobs o WHERE o.digest = b.digest AND o.project_id IS NOT NULL)
    """

    execute """
    UPDATE blobs SET project_id = (SELECT id FROM projects WHERE slug = 'default')
    WHERE project_id IS NULL
    """

    alter table(:blobs) do
      modify :project_id, :bigint, null: false
    end

    execute "ALTER TABLE blobs ADD PRIMARY KEY (project_id, digest)"

    # Orphan pruning anti-joins on the profile reference.
    create index(:invocations, [:profile_blob], where: "profile_blob IS NOT NULL")
  end

  def down do
    drop index(:invocations, [:profile_blob])
    execute "ALTER TABLE blobs DROP CONSTRAINT blobs_pkey"

    execute """
    DELETE FROM blobs b USING blobs o
    WHERE b.digest = o.digest AND b.project_id > o.project_id
    """

    execute "ALTER TABLE blobs ADD PRIMARY KEY (digest)"

    alter table(:blobs) do
      remove :project_id
      remove :prefix
    end
  end
end
