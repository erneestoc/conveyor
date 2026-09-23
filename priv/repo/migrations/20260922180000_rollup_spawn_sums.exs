defmodule Conveyor.Repo.Migrations.RollupSpawnSums do
  use Ecto.Migration

  @moduledoc """
  Execution-log sums per rolled-up hour (cache hits by mnemonic, cache misses by target,
  remote bytes), so the dashboard's spawn reports stop scanning `spawns`. Existing rows are
  dropped: they are derived data and reads rebuild the hours they need.
  """

  def up do
    alter table(:invocation_rollups) do
      add :spawns, :integer, null: false, default: 0
      add :spawn_mnemonics, :map, null: false, default: %{}
      add :spawn_misses, :map, null: false, default: %{}
      add :remote_sent, :bigint
      add :remote_fetched, :bigint
    end

    execute "DELETE FROM invocation_rollups"
  end

  def down do
    alter table(:invocation_rollups) do
      remove :spawns
      remove :spawn_mnemonics
      remove :spawn_misses
      remove :remote_sent
      remove :remote_fetched
    end
  end
end
