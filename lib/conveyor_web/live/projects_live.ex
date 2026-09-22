defmodule ConveyorWeb.ProjectsLive do
  @moduledoc """
  The root page: the projects this viewer may see, each with its last seven days at a
  glance and links into its builds, dashboard, tests and (for its admins) settings. The
  cross-project builds list lives at `/builds`.
  """
  use ConveyorWeb, :live_view

  alias Conveyor.Accounts.Scope
  alias Conveyor.Invocations
  alias Conveyor.Metrics.Dashboard
  alias ConveyorWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    projects = ConveyorWeb.Auth.visible_projects(scope)

    cards =
      for project <- projects do
        summary =
          Dashboard.summary(
            Conveyor.Metrics.Rollup.ensure!(Conveyor.Metrics.Scope.new("7d", project.id))
          )

        [last | _] = Invocations.list(project_id: project.id, limit: 1) ++ [nil]

        %{
          project: project,
          summary: summary,
          last: last,
          admin?: Scope.can_admin_project?(scope, project)
        }
      end

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       cards: cards,
       page_title: "Projects",
       current_path: "/"
     )}
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
      <div class="mb-4 flex items-end justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">Projects</h1>
          <p class="text-xs text-base-content/60">
            The last seven days of every project you can see.
          </p>
        </div>
        <.link navigate={~p"/builds"} id="all-builds-link" class="text-xs hover:underline">
          All builds →
        </.link>
      </div>

      <div id="projects" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <section
          :for={card <- @cards}
          id={"project-card-#{card.project.id}"}
          class="flex flex-col gap-3 rounded-md border border-base-300 p-4 transition hover:border-primary/60"
        >
          <div class="flex items-start justify-between gap-2">
            <.link navigate={~p"/p/#{card.project.slug}"} class="min-w-0">
              <h2 class="truncate text-sm font-semibold hover:underline">{card.project.name}</h2>
              <p class="font-mono text-[11px] text-base-content/50">{card.project.slug}</p>
            </.link>
            <span
              :if={card.summary.running > 0}
              class="rounded-full bg-sky-500/10 px-2 py-0.5 text-[11px] font-medium text-sky-600 dark:text-sky-400"
            >
              {card.summary.running} running
            </span>
          </div>

          <dl class="grid grid-cols-3 gap-2 text-xs">
            <div>
              <dt class="text-[11px] text-base-content/50">Builds</dt>
              <dd class="text-base font-semibold tabular-nums">{card.summary.builds}</dd>
            </div>
            <div>
              <dt class="text-[11px] text-base-content/50">Success</dt>
              <dd class="text-base font-semibold tabular-nums">
                {Format.percent(card.summary.succeeded, card.summary.succeeded + card.summary.failed)}
              </dd>
            </div>
            <div>
              <dt class="text-[11px] text-base-content/50">p50</dt>
              <dd class="text-base font-semibold tabular-nums">
                {Format.duration(card.summary.p50)}
              </dd>
            </div>
          </dl>

          <p class="text-[11px] text-base-content/60">
            <%= if card.last do %>
              Last build
              <.link navigate={~p"/invocation/#{card.last.id}"} class="hover:underline">
                {Format.relative(card.last.started_at || card.last.inserted_at, DateTime.utc_now())}
              </.link>
              · {card.last.status}
            <% else %>
              No builds yet
            <% end %>
          </p>

          <nav class="mt-auto flex flex-wrap gap-x-3 gap-y-1 text-xs">
            <.link navigate={~p"/p/#{card.project.slug}"} class="hover:underline">Builds</.link>
            <.link navigate={~p"/p/#{card.project.slug}/dashboard"} class="hover:underline">
              Dashboard
            </.link>
            <.link navigate={~p"/p/#{card.project.slug}/tests"} class="hover:underline">Tests</.link>
            <.link
              :if={card.admin?}
              navigate={~p"/p/#{card.project.slug}/settings"}
              class="hover:underline"
            >
              Settings
            </.link>
          </nav>
        </section>
        <p :if={@cards == []} id="no-projects" class="text-sm text-base-content/60">
          No projects to show. An admin creates projects in Settings.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
