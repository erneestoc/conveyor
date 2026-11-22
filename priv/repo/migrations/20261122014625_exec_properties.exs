defmodule Conveyor.Repo.Migrations.ExecProperties do
  use Ecto.Migration

  @moduledoc """
  The exec (platform) property names seen in a project's execution logs, so its admin can
  pick the one that states cores (PLAN §27.7). Additive: one small table, at most 100 rows
  per project, nothing per spawn.
  """

  def change do
    create table(:exec_properties, primary_key: false) do
      add :project_id, references(:projects, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :name, :text, null: false, primary_key: true
      add :spawns, :integer, null: false
      add :sample, :text
      add :last_seen_at, :utc_datetime_usec, null: false
    end
  end
end
