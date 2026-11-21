defmodule Conveyor.Rbe.Host do
  @moduledoc "A build host of a project and the starts of its three earliest builds."
  use Ecto.Schema

  @primary_key false
  schema "build_hosts" do
    field :project_id, :integer, primary_key: true
    field :host, :string, primary_key: true
    field :firsts, {:array, :utc_datetime_usec}, default: []
  end
end
