defmodule Conveyor.Repo.Migrations.RbeOpportunity do
  use Ecto.Migration

  @moduledoc """
  The RBE opportunity analysis (PLAN §27). Additive only: new nullable columns, one new
  index, three new tables; nothing a node of the previous release reads or writes changes.

    * `spawns`: the action key (the remote-execution action digest, or Conveyor's fallback
      key) and position in the log of an execution a cache could have served, and for every
      executed spawn its start and the cores it is charged with. A cache hit keeps all six
      null and grows by nothing.
    * `cache_groups`: a name projects share when they build one codebase against what
      should be one cache (`projects.settings["cache_group"]`).
    * `action_keys`: one row per `(scope, action key)` with the execution that finished
      first. A scope is a project (its id) or a cache group (minus its id). The row is the
      minimum of a total order over executions, so it does not depend on the order logs
      are parsed in (docs/spec/ActionKeys.tla).
    * `build_hosts`: the three earliest build starts of each host, for the cold-machine
      signal.
    * `invocation_rollups`: the two reports per hour.
    * `targets.cpus`: the `cpu:N` tag of a test target, when it has one.
  """

  def change do
    alter table(:spawns) do
      add :action_key, :binary
      add :started_at, :utc_datetime_usec
      add :ordinal, :integer
      add :cores_milli, :integer
      add :cores_source, :smallint
      add :key_source, :smallint
    end

    # The executions of a key, for the hours to mark stale when its first execution or its
    # flags change. Partial: cache hits and unkeyed executions are not in it.
    create index(:spawns, [:action_key], where: "action_key IS NOT NULL")

    create table(:action_keys, primary_key: false) do
      # No foreign key: a scope is a project or a group, and the rows of a scope that is
      # gone leave with retention (Conveyor.ExecLog.Keys.prune!/2).
      add :scope, :bigint, null: false, primary_key: true
      add :key, :binary, null: false, primary_key: true
      add :first_finish, :utc_datetime_usec, null: false
      add :first_start, :utc_datetime_usec, null: false
      add :first_invocation_id, :uuid, null: false
      add :first_ordinal, :integer, null: false
      add :last_finish, :utc_datetime_usec, null: false
      add :grp, :bigint
      add :multi, :boolean, null: false, default: false
      add :out, :bigint
      add :nondet, :boolean, null: false, default: false
    end

    create table(:cache_groups) do
      add :name, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:cache_groups, [:name])

    create table(:build_hosts, primary_key: false) do
      add :project_id, references(:projects, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :host, :text, null: false, primary_key: true
      add :firsts, {:array, :utc_datetime_usec}, null: false, default: []
    end

    alter table(:invocation_rollups) do
      add :fleet, :map
      add :rbe, :map
    end

    alter table(:targets) do
      add :cpus, :integer
    end
  end
end
