defmodule Conveyor.Repo.Migrations.CreateUsersAndAuditLog do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :subject, :string, null: false
      add :role, :string, null: false, default: "viewer"
      add :groups, {:array, :string}, null: false, default: []
      add :last_login_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:subject])
    create unique_index(:users, ["lower(email)"])

    create table(:audit_log) do
      add :actor, :string, null: false
      add :actor_type, :string, null: false
      add :action, :string, null: false
      add :subject_type, :string
      add :subject_id, :string
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :ip, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_log, [:inserted_at])
    create index(:audit_log, [:project_id, :inserted_at])
  end
end
