defmodule Conveyor.Blobs.Blob do
  @moduledoc "Metadata row for one content-addressed blob."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:digest, :string, autogenerate: false}
  schema "blobs" do
    field :size, :integer
    field :content_type, :string
    field :storage, :string
    field :source, :string, default: "fetch"
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
