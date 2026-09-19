defmodule Conveyor.Repo.Migrations.CreateBlobsAndArtifacts do
  use Ecto.Migration

  def change do
    # Content-addressed blobs (profiles, test logs, CAS uploads). The digest is the only key
    # and is validated before it ever reaches a path or an object key.
    create table(:blobs, primary_key: false) do
      add :digest, :string, primary_key: true
      add :size, :bigint, null: false
      add :content_type, :string
      add :storage, :string, null: false
      add :source, :string, null: false, default: "fetch"
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:blobs, [:expires_at], where: "expires_at IS NOT NULL")

    # Named files attached to an invocation: fetched from a remote cache, uploaded through
    # the HTTP API, or produced by a post-processing job.
    create table(:invocation_artifacts) do
      add :invocation_id,
          references(:invocations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :digest, :string, null: false
      add :size, :bigint, null: false
      add :content_type, :string
      add :source, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:invocation_artifacts, [:invocation_id, :name])
    create index(:invocation_artifacts, [:digest])
  end
end
