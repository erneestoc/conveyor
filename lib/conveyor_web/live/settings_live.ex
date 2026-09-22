defmodule ConveyorWeb.SettingsLive do
  @moduledoc """
  Projects and API keys. Keys are shown exactly once when created or rotated; only a hash is
  stored. Until OIDC (M6) lands, the page is reachable by everyone in open mode.
  """
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents

  alias Conveyor.Audit
  alias Conveyor.Projects
  alias Conveyor.Projects.{ApiKey, Project, Segments}
  alias ConveyorWeb.Format

  import ConveyorWeb.ProjectSettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings", project: nil, new_key: nil, current_path: "/settings")
     |> assign(
       project_form: to_form(Project.changeset(%Project{}, %{})),
       key_form: to_form(ApiKey.changeset(%ApiKey{}, %{}))
     )
     |> reload()}
  end

  defp reload(socket) do
    projects = Projects.list_projects()
    keys = Map.new(projects, &{&1.id, Projects.list_api_keys(&1)})

    assign(socket,
      projects: projects,
      keys: keys,
      segments: Map.new(projects, &{&1.id, Segments.list(&1.id)}),
      expiring: Projects.expiring_api_keys(14),
      audit: Audit.recent(50)
    )
  end

  @impl true
  def handle_event("create_project", %{"project" => attrs}, socket) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
        audit(socket, "project.create", subject: {"project", project.id}, project_id: project.id)

        {:noreply,
         socket
         |> put_flash(:info, "Project #{project.name} created")
         |> assign(project_form: to_form(Project.changeset(%Project{}, %{})))
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, project_form: to_form(changeset))}
    end
  end

  def handle_event("archive_project", %{"id" => id}, socket) do
    {:ok, project} = id |> Projects.get_project!() |> Projects.archive_project()
    audit(socket, "project.archive", subject: {"project", project.id}, project_id: project.id)
    {:noreply, socket |> put_flash(:info, "Project archived") |> reload()}
  end

  def handle_event(event, params, socket) do
    {:noreply, socket} = ConveyorWeb.ProjectSettings.handle_event(event, params, socket)
    {:noreply, reload(socket)}
  end

  defp audit(socket, action, opts), do: Audit.log(socket.assigns.current_scope, action, opts)

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
      <h1 class="text-lg font-semibold tracking-tight">Settings</h1>
      <p class="mb-4 text-xs text-base-content/60">
        Projects and the API keys Bazel clients use with
        <code class="font-mono">--bes_header=x-api-key=…</code>
      </p>

      <.new_key_notice new_key={@new_key} />

      <div
        :if={@expiring != []}
        id="expiring-keys"
        class="mb-4 rounded-md border border-amber-500/40 bg-amber-500/5 p-3 text-xs"
      >
        <b>Keys expiring within 14 days:</b>
        <span :for={k <- @expiring}>{k.project.name}/{k.name} ({Format.relative(
          k.expires_at,
          DateTime.utc_now()
        )})</span>
      </div>

      <.project_section
        :for={project <- @projects}
        project={project}
        keys={@keys[project.id] || []}
        segments={@segments[project.id] || []}
        key_form={@key_form}
        access?={true}
      />

      <.audit_table audit={@audit} />

      <section id="new-project" class="rounded-md border border-base-300 p-4">
        <h2 class="text-sm font-semibold">New project</h2>
        <.form
          for={@project_form}
          id="project-form"
          phx-submit="create_project"
          class="mt-2 flex flex-wrap items-end gap-2"
        >
          <.input field={@project_form[:slug]} label="Slug" placeholder="payments" />
          <.input field={@project_form[:name]} label="Name" placeholder="Payments" />
          <.button variant="primary">Create project</.button>
        </.form>
      </section>
      <.empty :if={@projects == []} title="No projects" />
    </Layouts.app>
    """
  end
end
