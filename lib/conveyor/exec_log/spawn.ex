defmodule Conveyor.ExecLog.Spawn do
  @moduledoc """
  One spawn from Bazel's compact execution log: an action that ran (or was served from the
  remote cache), with its inputs as a digest over `path → content digest` (the full sorted
  list is kept zstd-compressed in `inputs_blob` for diffs), its outputs and its timings.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "spawns" do
    belongs_to :invocation, Conveyor.Invocations.Invocation, type: :binary_id
    field :target_label, :string
    field :mnemonic, :string
    field :primary_output, :string, default: ""
    field :cache_hit, :boolean, default: false
    field :runner, :string
    field :exit_code, :integer
    field :status, :string
    field :remotable, :boolean
    field :cacheable, :boolean
    field :remote_cacheable, :boolean
    field :total_ms, :integer
    field :exec_ms, :integer
    field :queue_ms, :integer
    field :upload_ms, :integer
    field :fetch_ms, :integer
    field :setup_ms, :integer
    field :network_ms, :integer
    field :input_files, :integer, default: 0
    field :input_bytes, :integer, default: 0
    field :output_bytes, :integer, default: 0
    field :inputs_digest, :string
    field :outputs_digest, :string
    field :outputs, :map, default: %{}
    field :inputs_blob, :binary, load_in_query: false
    field :inserted_at, :utc_datetime_usec
  end

  @doc "The identity of an action across builds."
  @spec key(t() | map()) :: {String.t(), String.t(), String.t()}
  def key(%{target_label: l, mnemonic: m, primary_output: o}), do: {l, m, o}
end
