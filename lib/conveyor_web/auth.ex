defmodule ConveyorWeb.Auth do
  @moduledoc """
  LiveView `on_mount` hooks and helpers that apply the `Conveyor.Accounts.Scope`:
  sign-in in OIDC mode, admin-only pages, and per-project visibility.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias Conveyor.Accounts.Scope
  alias Conveyor.Invocations
  alias Conveyor.Projects

  def on_mount(:default, _params, session, socket) do
    scope = Scope.from_session(session)
    socket = assign(socket, :current_scope, scope)

    if scope.mode == :oidc and is_nil(scope.user),
      do: {:halt, redirect(socket, to: "/auth/login")},
      else: {:cont, socket}
  end

  def on_mount(:admin, _params, _session, socket) do
    if socket.assigns.current_scope.admin? do
      {:cont, socket}
    else
      {:halt, socket |> put_flash(:error, "Admin access required") |> redirect(to: "/")}
    end
  end

  @doc "Projects the scope may see (for switchers and lists)."
  @spec visible_projects(Scope.t(), keyword()) :: [Projects.Project.t()]
  def visible_projects(%Scope{} = scope, opts \\ []),
    do: Scope.visible_projects(scope, Projects.list_projects(opts))

  @doc "A project by slug, or nil when it does not exist or the scope may not see it."
  @spec visible_project_by_slug(Scope.t(), String.t()) :: Projects.Project.t() | nil
  def visible_project_by_slug(%Scope{} = scope, slug) do
    case Projects.get_project_by_slug(slug) do
      nil -> nil
      project -> if Scope.can_view_project?(scope, project), do: project, else: nil
    end
  end

  @doc "The project ids a scope may read (`Conveyor.Accounts.Scope.project_ids/1`), for read paths."
  @spec project_ids(Scope.t() | Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: :all | [integer()]
  def project_ids(%Scope{} = scope), do: Scope.project_ids(scope)
  def project_ids(%{assigns: %{current_scope: scope}}), do: Scope.project_ids(scope)

  @doc """
  Loads an invocation the scope may see, raising `ConveyorWeb.NotFoundError` otherwise.
  The project restriction is part of the lookup: an id in another project is not found.
  """
  @spec invocation!(Scope.t() | Plug.Conn.t(), String.t()) :: Invocations.Invocation.t()
  def invocation!(%Plug.Conn{assigns: %{current_scope: scope}}, id), do: invocation!(scope, id)

  def invocation!(%Scope{} = scope, id) do
    Invocations.get(id, project_ids: Scope.project_ids(scope)) ||
      raise ConveyorWeb.NotFoundError, "no invocation #{id}"
  end
end
