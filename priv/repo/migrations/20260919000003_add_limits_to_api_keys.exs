defmodule Conveyor.Repo.Migrations.AddLimitsToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :limits, :map, null: false, default: %{}
    end
  end
end
