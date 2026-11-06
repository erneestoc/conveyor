defmodule Conveyor.Repo.Migrations.CreateRawLogObjects do
  use Ecto.Migration

  # Every raw-log object is registered before it is written, so the sweep can delete old
  # objects (and orphans of failed commits) without listing the store.
  def change do
    create table(:raw_log_objects, primary_key: false) do
      add :key, :text, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:raw_log_objects, [:inserted_at])
  end
end
