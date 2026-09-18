defmodule Conveyor.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :settings, :map, null: false, default: %{}
      add :archived_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:slug])

    create table(:api_keys) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :key_id, :string, null: false
      add :key_hash, :binary, null: false
      add :name, :string, null: false
      add :scopes, {:array, :string}, null: false, default: ["ingest"]
      add :default_tags, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :last_used_ip, :string
      add :rotated_from_id, references(:api_keys, on_delete: :nilify_all)
      add :created_by, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_id])
    create index(:api_keys, [:project_id])

    create table(:invocations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :api_key_id, references(:api_keys, on_delete: :nilify_all)
      add :build_id, :string
      add :bes_instance_name, :string
      add :status, :string, null: false, default: "in_progress"
      add :exit_code_name, :string
      add :exit_code, :integer
      add :abort_reason, :string
      add :abort_description, :text
      add :command, :string
      add :patterns, {:array, :text}, null: false, default: []
      add :options_description, :text
      add :bazel_version, :string
      add :host, :string
      add :user_name, :string
      add :cwd, :text
      add :workspace, :text
      add :local_exec_root, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :last_event_seq, :bigint, null: false, default: 0
      add :last_event_at, :utc_datetime_usec
      add :stream_finished, :boolean, null: false, default: false
      add :lifecycle_finished, :boolean, null: false, default: false
      add :tags, :map, null: false, default: %{}
      add :keywords, {:array, :text}, null: false, default: []
      add :configurations, :map, null: false, default: %{}
      add :options, :map, null: false, default: %{}
      add :workspace_status, :map, null: false, default: %{}
      add :event_count, :bigint, null: false, default: 0
      add :log_bytes, :bigint, null: false, default: 0
      add :log_lines, :integer, null: false, default: 0
      add :targets_configured, :integer, null: false, default: 0
      add :targets_completed, :integer, null: false, default: 0
      add :targets_failed, :integer, null: false, default: 0
      add :tests_total, :integer, null: false, default: 0
      add :tests_passed, :integer, null: false, default: 0
      add :tests_failed, :integer, null: false, default: 0
      add :tests_flaky, :integer, null: false, default: 0
      add :tests_timed_out, :integer, null: false, default: 0
      add :actions_created, :bigint
      add :actions_executed, :bigint
      add :actions_failed, :integer, null: false, default: 0
      add :remote_cache_hits, :bigint
      add :remote_exec, :integer
      add :local_exec, :integer
      add :worker_exec, :integer
      add :sandbox_exec, :integer
      add :action_cache_hits, :bigint
      add :action_cache_misses, :bigint
      add :analysis_ms, :bigint
      add :execution_ms, :bigint
      add :critical_path_ms, :bigint
      add :cpu_ms, :bigint
      add :wall_ms, :bigint
      add :peak_heap_bytes, :bigint
      add :packages_loaded, :integer
      add :bytes_sent, :bigint
      add :bytes_recv, :bigint
      add :profile_status, :string, null: false, default: "none"
      add :profile_uri, :text
      add :profile_blob, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:invocations, [:project_id, "started_at DESC"])
    create index(:invocations, [:project_id, :status, "started_at DESC"])
    create index(:invocations, [:build_id])

    execute(
      "CREATE INDEX invocations_tags_gin ON invocations USING GIN (tags jsonb_path_ops)",
      "DROP INDEX invocations_tags_gin"
    )

    create index(:invocations, [:status, :last_event_at])

    # Raw BEP events and log text live in compressed segments, range-partitioned by the
    # invocation's start day so that retention is a partition drop and reads prune to one
    # partition. Partitions are created by Conveyor.Storage.Partitions.
    execute(
      """
      CREATE TABLE event_segments (
        invocation_id uuid NOT NULL,
        day date NOT NULL,
        first_seq bigint NOT NULL,
        last_seq bigint NOT NULL,
        count integer NOT NULL,
        kinds text[] NOT NULL DEFAULT '{}',
        byte_size integer NOT NULL,
        payload bytea NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (day, invocation_id, first_seq)
      ) PARTITION BY RANGE (day)
      """,
      "DROP TABLE event_segments"
    )

    execute("CREATE TABLE event_segments_default PARTITION OF event_segments DEFAULT", "")

    execute(
      """
      CREATE TABLE log_segments (
        invocation_id uuid NOT NULL,
        day date NOT NULL,
        first_seq bigint NOT NULL,
        last_seq bigint NOT NULL,
        byte_offset bigint NOT NULL,
        line_offset integer NOT NULL,
        byte_size integer NOT NULL,
        line_count integer NOT NULL,
        data bytea NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (day, invocation_id, first_seq)
      ) PARTITION BY RANGE (day)
      """,
      "DROP TABLE log_segments"
    )

    execute("CREATE TABLE log_segments_default PARTITION OF log_segments DEFAULT", "")

    create table(:targets) do
      add :invocation_id, references(:invocations, type: :uuid, on_delete: :delete_all),
        null: false

      add :label, :text, null: false
      add :configuration_id, :string, null: false, default: ""
      add :aspect, :string, null: false, default: ""
      add :kind, :string
      add :test_size, :string
      add :status, :string, null: false, default: "configured"
      add :test_status, :string
      add :failure_message, :text
      add :output_groups, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :bigint
    end

    create unique_index(:targets, [:invocation_id, :label, :aspect])

    create table(:test_results) do
      add :invocation_id, references(:invocations, type: :uuid, on_delete: :delete_all),
        null: false

      add :label, :text, null: false
      add :configuration_id, :string, null: false, default: ""
      add :run, :integer, null: false, default: 1
      add :shard, :integer, null: false, default: 1
      add :attempt, :integer, null: false, default: 1
      add :status, :string
      add :cached_locally, :boolean, null: false, default: false
      add :cached_remotely, :boolean, null: false, default: false
      add :strategy, :string
      add :hostname, :string
      add :started_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :exit_code, :integer
      add :files, :map, null: false, default: %{}
      add :warnings, {:array, :text}, null: false, default: []
    end

    create unique_index(:test_results, [
             :invocation_id,
             :label,
             :configuration_id,
             :run,
             :shard,
             :attempt
           ])

    create table(:actions) do
      add :invocation_id, references(:invocations, type: :uuid, on_delete: :delete_all),
        null: false

      add :seq, :bigint, null: false
      add :label, :text
      add :configuration_id, :string
      add :mnemonic, :string
      add :success, :boolean, null: false, default: false
      add :exit_code, :integer
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :primary_output, :text
      add :stdout_uri, :text
      add :stderr_uri, :text
      add :command_line, {:array, :text}, null: false, default: []
      add :failure_message, :text
    end

    create unique_index(:actions, [:invocation_id, :seq])

    create table(:invocation_metrics, primary_key: false) do
      add :invocation_id, references(:invocations, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :build_metrics, :map, null: false, default: %{}
      add :tool_logs, :map, null: false, default: %{}
      add :profile_summary, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create table(:named_sets) do
      add :invocation_id, references(:invocations, type: :uuid, on_delete: :delete_all),
        null: false

      add :set_id, :string, null: false
      add :files, :map, null: false, default: %{}
      add :child_set_ids, {:array, :string}, null: false, default: []
    end

    create unique_index(:named_sets, [:invocation_id, :set_id])

    create table(:tag_keys) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :text, null: false
      add :count, :bigint, null: false, default: 0
      add :last_seen_at, :utc_datetime_usec
    end

    create unique_index(:tag_keys, [:project_id, :key, :value])
  end
end
