defmodule Conveyor.Accounts do
  @moduledoc """
  Users and sign-in policy. Configuration under `config :conveyor, Conveyor.Accounts`:

    * `:mode` — `:open` (no sign-in) or `:oidc`
    * `:admin_token` — open mode: unlock Settings with this token (nil = open to all)
    * `:oidc` — `client_id`, `client_secret`, `base_url` (issuer), `scopes`
    * `:admin_emails`, `:admin_groups`, `:groups_claim`, `:allowed_email_domains`
  """
  import Ecto.Query

  alias Conveyor.Accounts.User
  alias Conveyor.Repo

  def config(key, default \\ nil),
    do: Application.get_env(:conveyor, __MODULE__, []) |> Keyword.get(key, default)

  @spec mode() :: :open | :oidc
  def mode, do: config(:mode, :open)

  @doc "The admin token for open mode, or nil when settings are open to everyone."
  def admin_token do
    case config(:admin_token) do
      t when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  @doc "Assent configuration for the OIDC strategy."
  @spec oidc_config(String.t()) :: keyword()
  def oidc_config(redirect_uri) do
    oidc = config(:oidc, [])

    [
      client_id: Keyword.get(oidc, :client_id),
      client_secret: Keyword.get(oidc, :client_secret),
      base_url: Keyword.get(oidc, :base_url),
      redirect_uri: redirect_uri,
      authorization_params: [scope: Keyword.get(oidc, :scopes, "openid email profile")],
      code_verifier: true,
      http_adapter: Assent.HTTPAdapter.Httpc
    ]
  end

  @spec get_user(integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from u in User, order_by: u.email)

  @doc """
  Creates or updates the user for a set of ID token claims, applying the email domain
  allow-list and deriving the role from admin emails / groups on every login.
  """
  @spec upsert_from_claims(map()) :: {:ok, User.t()} | {:error, :no_email | :domain_not_allowed}
  def upsert_from_claims(claims) do
    email = claims["email"]
    subject = claims["sub"] || email

    groups =
      case claims[config(:groups_claim, "groups")] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> []
      end

    cond do
      not is_binary(email) or email == "" -> {:error, :no_email}
      not domain_allowed?(email) -> {:error, :domain_not_allowed}
      true -> upsert(subject, email, claims["name"], groups)
    end
  end

  defp upsert(subject, email, name, groups) do
    now = DateTime.utc_now()

    row = %{
      subject: subject,
      email: email,
      name: name,
      role: role_for(email, groups),
      groups: groups,
      last_login_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, [user]} =
      Repo.insert_all(User, [row],
        on_conflict: {:replace, [:email, :name, :role, :groups, :last_login_at, :updated_at]},
        conflict_target: :subject,
        returning: true
      )

    {:ok, user}
  end

  @doc "admin when the email is listed in ADMIN_EMAILS or any group is in OIDC_ADMIN_GROUPS."
  @spec role_for(String.t(), [String.t()]) :: String.t()
  def role_for(email, groups) do
    admin_emails = config(:admin_emails, []) |> Enum.map(&String.downcase/1)
    admin_groups = config(:admin_groups, [])

    if String.downcase(email) in admin_emails or Enum.any?(groups, &(&1 in admin_groups)),
      do: "admin",
      else: "viewer"
  end

  defp domain_allowed?(email) do
    case config(:allowed_email_domains, []) do
      [] ->
        true

      domains ->
        domain = email |> String.split("@") |> List.last() |> String.downcase()
        domain in Enum.map(domains, &String.downcase/1)
    end
  end

  @doc "Parses a comma-separated environment value into a list."
  @spec csv(String.t() | nil) :: [String.t()]
  def csv(nil), do: []
  def csv(s), do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end
