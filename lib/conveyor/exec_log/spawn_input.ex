defmodule Conveyor.ExecLog.SpawnInput do
  @moduledoc """
  The sorted `path\\tdigest` input list of a spawn, zstd-compressed, stored once per project
  and digest and shared by every spawn with identical inputs (`spawns.inputs_digest`).
  Every build of the same sources repeats the same lists, so this holds a few percent of
  what copying the list into each spawn row did. `touched_at` is refreshed by every store
  that references the list; orphan pruning (`Conveyor.ExecLog.prune_orphan_inputs/2`)
  removes lists older than a grace period that no spawn references (docs/spec/SpawnInputs.tla).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "spawn_inputs" do
    field :project_id, :integer, primary_key: true
    field :digest, :string, primary_key: true
    field :blob, :binary
    field :touched_at, :utc_datetime_usec
  end
end
