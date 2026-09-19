defmodule Conveyor.Audit.Entry do
  @moduledoc "One audit log row: who did what to which subject."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "audit_log" do
    field :actor, :string
    field :actor_type, :string
    field :action, :string
    field :subject_type, :string
    field :subject_id, :string
    belongs_to :project, Conveyor.Projects.Project
    field :ip, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
