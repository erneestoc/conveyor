defmodule Conveyor.Invocations.Invocation do
  @moduledoc "One Bazel command (`bazel build/test/...`), keyed by Bazel's invocation UUID."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(in_progress succeeded failed aborted disconnected unknown)

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "invocations" do
    belongs_to :project, Conveyor.Projects.Project
    belongs_to :api_key, Conveyor.Projects.ApiKey
    field :build_id, :string
    field :bes_instance_name, :string
    field :status, :string, default: "in_progress"
    field :exit_code_name, :string
    field :exit_code, :integer
    field :abort_reason, :string
    field :abort_description, :string
    field :command, :string
    field :patterns, {:array, :string}, default: []
    field :options_description, :string
    field :bazel_version, :string
    field :host, :string
    field :user_name, :string
    field :cwd, :string
    field :workspace, :string
    field :local_exec_root, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :last_event_seq, :integer, default: 0
    field :last_event_at, :utc_datetime_usec
    field :stream_finished, :boolean, default: false
    field :lifecycle_finished, :boolean, default: false
    field :tags, :map, default: %{}
    field :keywords, {:array, :string}, default: []
    field :configurations, :map, default: %{}
    field :options, :map, default: %{}
    field :workspace_status, :map, default: %{}
    field :event_count, :integer, default: 0
    field :log_bytes, :integer, default: 0
    field :log_lines, :integer, default: 0
    field :targets_configured, :integer, default: 0
    field :targets_completed, :integer, default: 0
    field :targets_failed, :integer, default: 0
    field :tests_total, :integer, default: 0
    field :tests_passed, :integer, default: 0
    field :tests_failed, :integer, default: 0
    field :tests_flaky, :integer, default: 0
    field :tests_timed_out, :integer, default: 0
    field :actions_created, :integer
    field :actions_executed, :integer
    field :actions_failed, :integer, default: 0
    field :remote_cache_hits, :integer
    field :remote_exec, :integer
    field :local_exec, :integer
    field :worker_exec, :integer
    field :sandbox_exec, :integer
    field :action_cache_hits, :integer
    field :action_cache_misses, :integer
    field :analysis_ms, :integer
    field :execution_ms, :integer
    field :critical_path_ms, :integer
    field :cpu_ms, :integer
    field :wall_ms, :integer
    field :peak_heap_bytes, :integer
    field :packages_loaded, :integer
    field :bytes_sent, :integer
    field :bytes_recv, :integer
    field :profile_status, :string, default: "none"
    field :profile_uri, :string
    field :profile_blob, :string
    has_one :metrics, Conveyor.Invocations.Metrics
    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "Columns the ingest worker is allowed to set on each batch commit."
  def ingest_fields do
    __schema__(:fields) --
      [:id, :project_id, :api_key_id, :inserted_at, :updated_at, :last_event_seq]
  end
end
