defmodule Conveyor.Projects.ApiKey do
  @moduledoc """
  An ingest/upload/read credential scoped to one project.

  Plaintext keys look like `conveyor_<key_id>_<secret>`; only `sha256(secret)` is stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @scopes ~w(ingest upload read)

  schema "api_keys" do
    belongs_to :project, Conveyor.Projects.Project
    field :key_id, :string
    field :key_hash, :binary
    field :name, :string
    field :scopes, {:array, :string}, default: ["ingest"]
    field :default_tags, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :last_used_ip, :string
    belongs_to :rotated_from, __MODULE__
    field :created_by, :string
    timestamps(type: :utc_datetime_usec)
  end

  def scopes, do: @scopes

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:name, :scopes, :default_tags, :expires_at, :created_by])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_subset(:scopes, @scopes)
    |> validate_change(:scopes, fn :scopes, s ->
      if s == [], do: [scopes: "must include at least one scope"], else: []
    end)
    |> validate_change(:default_tags, &validate_tags/2)
  end

  defp validate_tags(field, tags) do
    if Enum.all?(tags, fn {k, v} -> is_binary(k) and is_binary(v) and k != "" end),
      do: [],
      else: [{field, "must be a map of non-empty string keys to string values"}]
  end

  @doc "True when the key can be used right now."
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{revoked_at: nil, expires_at: nil}, _now), do: true
  def active?(%__MODULE__{revoked_at: %DateTime{}}, _now), do: false
  def active?(%__MODULE__{expires_at: exp}, now), do: DateTime.compare(exp, now) == :gt
end
