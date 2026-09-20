defmodule Conveyor.Repo.Migrations.IndexSpawnDigests do
  use Ecto.Migration

  # The non-hermetic report self-joins spawns on identical inputs.
  def change do
    create index(:spawns, [:inputs_digest])
  end
end
