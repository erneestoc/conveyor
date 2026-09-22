defmodule ConveyorWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ConveyorWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :projects, :list, default: [], doc: "projects for the switcher"
  attr :project, :any, default: nil, doc: "the selected project, or nil for all projects"
  attr :current_path, :string, default: "/", doc: "used to highlight the active nav item"
  attr :wide, :boolean, default: true, doc: "use the full viewport width"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-base-100 text-base-content">
      <header class="sticky top-0 z-30 border-b border-base-300/70 bg-base-100/90 backdrop-blur">
        <div class="mx-auto flex h-12 max-w-screen-2xl items-center gap-4 px-4 sm:px-6">
          <.link
            navigate={~p"/"}
            class="flex items-center gap-2 font-semibold tracking-tight"
            id="brand"
          >
            <span class="grid size-6 place-items-center rounded bg-primary text-primary-content">
              <.icon name="hero-forward-micro" class="size-3.5" />
            </span>
            Conveyor
          </.link>

          <.project_switcher projects={@projects} project={@project} />

          <nav class="ml-2 hidden items-center gap-1 text-sm sm:flex" id="main-nav">
            <.nav_link
              navigate={builds_path(@project)}
              active={
                String.starts_with?(@current_path, "/p/") or @current_path == "/" or
                  String.starts_with?(@current_path, "/invocation/")
              }
            >
              Builds
            </.nav_link>
            <.nav_link
              navigate={sub_path(@project, "dashboard")}
              active={String.ends_with?(@current_path, "/dashboard")}
            >Dashboard</.nav_link>
            <.nav_link
              navigate={sub_path(@project, "tests")}
              active={String.ends_with?(@current_path, "/tests")}
            >Tests</.nav_link>
            <.nav_link
              :if={@project && project_admin?(@current_scope, @project)}
              navigate={sub_path(@project, "settings")}
              active={String.ends_with?(@current_path, "/settings")}
            >Project settings</.nav_link>
          </nav>

          <div class="ml-auto flex items-center gap-3">
            <span
              :if={@current_scope && @current_scope.user}
              id="nav-user"
              class="hidden text-xs text-base-content/60 sm:inline"
              title={@current_scope.user.role}
            >
              {@current_scope.user.email}
            </span>
            <.link
              :if={admin?(@current_scope)}
              navigate={~p"/settings"}
              class={[
                "rounded px-2 py-1 text-sm hover:bg-base-200",
                @current_path == "/settings" && "bg-base-200 font-medium"
              ]}
              id="nav-settings"
              title="Projects and API keys"
            >
              <.icon name="hero-cog-6-tooth-micro" class="size-4" />
            </.link>
            <.link
              :if={@current_scope && @current_scope.mode == :open && !@current_scope.admin?}
              navigate={~p"/auth/login"}
              id="nav-admin-login"
              class="rounded px-2 py-1 text-sm hover:bg-base-200"
              title="Unlock settings with the admin token"
            >
              <.icon name="hero-lock-closed-micro" class="size-4" />
            </.link>
            <.link
              :if={@current_scope && (@current_scope.user || @current_scope.admin_session?)}
              href={~p"/auth/logout"}
              method="delete"
              id="nav-logout"
              class="rounded px-2 py-1 text-xs hover:bg-base-200"
            >
              Sign out
            </.link>
            <.theme_toggle />
          </div>
        </div>
      </header>

      <main class={[
        "mx-auto w-full flex-1 px-4 py-4 sm:px-6",
        @wide && "max-w-screen-2xl",
        !@wide && "max-w-3xl"
      ]}>
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp admin?(%{admin?: admin}), do: admin
  defp admin?(_), do: false

  defp project_admin?(%Conveyor.Accounts.Scope{} = scope, project),
    do: Conveyor.Accounts.Scope.can_admin_project?(scope, project)

  defp project_admin?(_, _), do: false

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "rounded px-2 py-1 transition-colors hover:bg-base-200",
        @active && "bg-base-200 font-medium text-base-content",
        !@active && "text-base-content/70"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :projects, :list, required: true
  attr :project, :any, required: true

  defp project_switcher(assigns) do
    ~H"""
    <details class="relative" id="project-switcher">
      <summary class="flex cursor-pointer select-none items-center gap-1 rounded border border-base-300 bg-base-100 px-2 py-1 text-sm hover:bg-base-200">
        <.icon name="hero-folder-micro" class="size-3.5 text-base-content/60" />
        <span class="max-w-40 truncate">{if @project, do: @project.name, else: "All projects"}</span>
        <.icon name="hero-chevron-down-micro" class="size-3.5 text-base-content/60" />
      </summary>
      <div class="absolute left-0 mt-1 w-56 rounded-md border border-base-300 bg-base-100 p-1 shadow-lg">
        <.link
          navigate={~p"/"}
          class={[
            "block rounded px-2 py-1.5 text-sm hover:bg-base-200",
            is_nil(@project) && "font-medium"
          ]}
        >
          All projects
        </.link>
        <.link
          :for={p <- @projects}
          navigate={~p"/p/#{p.slug}"}
          class={[
            "block truncate rounded px-2 py-1.5 text-sm hover:bg-base-200",
            @project && @project.id == p.id && "font-medium"
          ]}
        >
          {p.name}
        </.link>
      </div>
    </details>
    """
  end

  defp builds_path(nil), do: ~p"/"
  defp builds_path(project), do: ~p"/p/#{project.slug}"

  defp sub_path(nil, page), do: "/#{page}"
  defp sub_path(project, page), do: "/p/#{project.slug}/#{page}"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
