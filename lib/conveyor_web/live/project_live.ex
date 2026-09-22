defmodule ConveyorWeb.ProjectLive do
  @moduledoc """
  A project's own settings page (`/p/:slug/settings`): API keys, storage, remote cache
  endpoints, dashboard segments and the project's audit trail, for global admins and the
  members of the project's admin groups. Access control itself (who may see or manage the
  project) stays on the global Settings page.
  """
  use ConveyorWeb, :live_view

  import ConveyorWeb.ProjectSettingsComponents

  alias Conveyor.Accounts.Scope
  alias Conveyor.Audit
  alias Conveyor.Projects
  alias Conveyor.Projects.{ApiKey, Segments}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    scope = socket.assigns.current_scope

    project =
      ConveyorWeb.Auth.visible_project_by_slug(scope, slug) ||
        raise ConveyorWeb.NotFoundError, "no project #{slug}"

    unless Scope.can_admin_project?(scope, project),
      do: raise(ConveyorWeb.NotFoundError, "no project #{slug}")

    {:ok,
     socket
     |> assign(
       project: project,
       projects: ConveyorWeb.Auth.visible_projects(scope),
       page_title: "#{project.name} settings",
       current_path: "/p/#{slug}/settings",
       new_key: nil,
       key_form: to_form(ApiKey.changeset(%ApiKey{}, %{}))
     )
     |> reload()}
  end

  defp reload(socket) do
    project = Projects.get_project!(socket.assigns.project.id)

    assign(socket,
      project: project,
      keys: Projects.list_api_keys(project),
      segments: Segments.list(project.id),
      audit: Audit.recent(50, project_id: project.id)
    )
  end

  @impl true
  def handle_event(event, params, socket) do
    {:noreply, socket} = ConveyorWeb.ProjectSettings.handle_event(event, params, socket)
    {:noreply, reload(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      projects={@projects}
      project={@project}
      current_path={@current_path}
      wide={false}
    >
      <h1 class="text-lg font-semibold tracking-tight" id="project-settings-title">
        {@project.name} <span class="font-mono text-xs text-base-content/50">{@project.slug}</span>
      </h1>
      <p class="mb-4 text-xs text-base-content/60">
        Keys, retention, remote cache endpoints and dashboard segments of this project.
        <span :if={@current_scope.admin?}>
          Who may see or administer it is set in <.link navigate={~p"/settings"} class="underline">Settings</.link>.
        </span>
      </p>

      <.new_key_notice new_key={@new_key} />

      <.project_section
        project={@project}
        keys={@keys}
        segments={@segments}
        key_form={@key_form}
        access?={false}
      />

      <.audit_table
        audit={@audit}
        description="Key, storage, endpoint and segment changes and uploads of this project. Latest 50."
      />
    </Layouts.app>
    """
  end
end
