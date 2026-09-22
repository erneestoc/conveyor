defmodule Conveyor.Repo.Migrations.CreateInvocationRollups do
  use Ecto.Migration

  @moduledoc """
  Hourly per-project rollups of the dashboard's inputs (PLAN §24 item 6): counts by status,
  cache and action sums, distinct users, a duration digest for percentiles, per-phase and
  per-mnemonic sums. Maintained by `Conveyor.Workers.Rollup`; read by
  `Conveyor.Metrics.Dashboard` for scopes without a free-form query.
  """

  def change do
    create table(:invocation_rollups, primary_key: false) do
      add :project_id, references(:projects, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :hour, :utc_datetime, null: false, primary_key: true
      add :builds, :integer, null: false, default: 0
      add :succeeded, :integer, null: false, default: 0
      add :failed, :integer, null: false, default: 0
      add :aborted, :integer, null: false, default: 0
      add :running, :integer, null: false, default: 0
      add :other, :integer, null: false, default: 0
      # sums over every build (series) and over finished builds (summary); null when no
      # build carried the number, like the SQL sums they replace
      add :cache_hits_all, :bigint
      add :executed_all, :bigint
      add :cache_hits, :bigint
      add :executed, :bigint
      add :users, {:array, :text}, null: false, default: []
      add :durations, :map, null: false, default: %{}
      add :phases, :map, null: false, default: %{}
      add :queued_ms, :float
      add :profiled, :integer, null: false, default: 0
      add :mnemonic_counts, :map, null: false, default: %{}
      add :mnemonic_ms, :map, null: false, default: %{}
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:invocation_rollups, [:hour])
  end
end
