defmodule Conveyor.Repo.Migrations.CreateSpawns do
  use Ecto.Migration

  def change do
    create table(:spawns) do
      add :invocation_id, references(:invocations, type: :uuid, on_delete: :delete_all),
        null: false

      add :target_label, :text, null: false
      add :mnemonic, :string, null: false
      add :primary_output, :text, null: false, default: ""
      add :cache_hit, :boolean, null: false, default: false
      add :runner, :string
      add :exit_code, :integer
      add :status, :string
      add :remotable, :boolean
      add :cacheable, :boolean
      add :remote_cacheable, :boolean
      add :total_ms, :integer
      add :exec_ms, :integer
      add :queue_ms, :integer
      add :upload_ms, :integer
      add :fetch_ms, :integer
      add :setup_ms, :integer
      add :network_ms, :integer
      add :input_files, :integer, null: false, default: 0
      add :input_bytes, :bigint, null: false, default: 0
      add :output_bytes, :bigint, null: false, default: 0
      add :inputs_digest, :string, null: false
      add :outputs_digest, :string, null: false
      add :outputs, :map, null: false, default: %{}
      add :inputs_blob, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:spawns, [:invocation_id, :target_label, :mnemonic])

    alter table(:invocations) do
      add :exec_log_status, :string, null: false, default: "none"
    end
  end
end
