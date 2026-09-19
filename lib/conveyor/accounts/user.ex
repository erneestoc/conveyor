defmodule Conveyor.Accounts.User do
  @moduledoc "A person who signed in through the identity provider."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @roles ~w(viewer admin)

  schema "users" do
    field :email, :string
    field :name, :string
    field :subject, :string
    field :role, :string, default: "viewer"
    field :groups, {:array, :string}, default: []
    field :last_login_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles
end
