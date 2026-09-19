defmodule Conveyor.Accounts.Scope do
  @moduledoc """
  Who is looking: derived from the session on every request and LiveView mount.

    * open mode — nobody signs in; everyone can view builds. Settings are open unless
      `ADMIN_TOKEN` is set, in which case an unlocked session (`admin_session?`) is needed.
    * oidc mode — a signed-in `user` is required for every page; admins come from
      `ADMIN_EMAILS` / `OIDC_ADMIN_GROUPS`; projects may be restricted to groups.
  """
  alias Conveyor.Accounts
  alias Conveyor.Accounts.User

  @type t :: %__MODULE__{
          mode: :open | :oidc,
          user: User.t() | nil,
          admin?: boolean(),
          admin_session?: boolean()
        }

  defstruct mode: :open, user: nil, admin?: false, admin_session?: false

  @doc "Builds the scope for a Plug or LiveView session map."
  @spec from_session(map()) :: t()
  def from_session(session) do
    case Accounts.mode() do
      :open ->
        unlocked = session["admin"] == true
        token_set = Accounts.admin_token() != nil
        %__MODULE__{mode: :open, admin?: not token_set or unlocked, admin_session?: unlocked}

      :oidc ->
        user =
          case session["user_id"] do
            id when is_integer(id) -> Accounts.get_user(id)
            _ -> nil
          end

        %__MODULE__{mode: :oidc, user: user, admin?: user != nil and user.role == "admin"}
    end
  end

  @doc "A label for audit entries."
  @spec actor(t()) :: String.t()
  def actor(%__MODULE__{user: %User{email: email}}), do: email
  def actor(%__MODULE__{admin_session?: true}), do: "admin-token"
  def actor(%__MODULE__{}), do: "anonymous"

  @doc "True when the scope may see a project (group restrictions apply to viewers only)."
  @spec can_view_project?(t(), map()) :: boolean()
  def can_view_project?(%__MODULE__{admin?: true}, _project), do: true

  def can_view_project?(%__MODULE__{user: user}, %{settings: settings}) do
    case Map.get(settings || %{}, "allowed_groups", []) do
      [] -> true
      groups when user != nil -> Enum.any?(groups, &(&1 in user.groups))
      _ -> false
    end
  end

  @doc "Filters projects down to those the scope may see."
  @spec visible_projects(t(), [map()]) :: [map()]
  def visible_projects(scope, projects), do: Enum.filter(projects, &can_view_project?(scope, &1))
end
