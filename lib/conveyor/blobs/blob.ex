defmodule Conveyor.Blobs.Blob do
  @moduledoc """
  Metadata row for one content-addressed blob of one project. `prefix` is the key prefix
  the bytes were stored under (nil for blobs written before prefixes existed).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "blobs" do
    field :project_id, :integer, primary_key: true
    field :digest, :string, primary_key: true
    field :prefix, :string
    field :size, :integer
    field :content_type, :string
    field :storage, :string
    field :source, :string, default: "fetch"
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
