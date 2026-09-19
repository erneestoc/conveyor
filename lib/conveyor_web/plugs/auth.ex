defmodule ConveyorWeb.Plugs.Auth do
  @moduledoc "Puts the `Conveyor.Accounts.Scope` in `conn.assigns` and enforces sign-in in OIDC mode."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias Conveyor.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = Scope.from_session(get_session(conn))
    conn = assign(conn, :current_scope, scope)

    if scope.mode == :oidc and is_nil(scope.user) and not auth_path?(conn) do
      conn
      |> put_session(:return_to, safe_return_to(conn.request_path))
      |> redirect(to: "/auth/login")
      |> halt()
    else
      conn
    end
  end

  @doc "Halts non-admins (used for controller routes; LiveViews use `ConveyorWeb.Auth`)."
  def require_admin(conn, _opts) do
    if conn.assigns.current_scope.admin? do
      conn
    else
      conn |> put_flash(:error, "Admin access required") |> redirect(to: "/") |> halt()
    end
  end

  defp auth_path?(%Plug.Conn{path_info: ["auth" | _]}), do: true
  defp auth_path?(_), do: false

  @doc "Only local paths are accepted as post-login destinations."
  def safe_return_to("//" <> _), do: "/"
  def safe_return_to("/" <> _ = path), do: path
  def safe_return_to(_), do: "/"
end
