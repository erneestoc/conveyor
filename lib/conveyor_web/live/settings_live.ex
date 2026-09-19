defmodule ConveyorWeb.SettingsLive do
  @moduledoc """
  Projects and API keys. Keys are shown exactly once when created or rotated; only a hash is
  stored. Until OIDC (M6) lands, the page is reachable by everyone in open mode.
  """
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents

  alias Conveyor.Projects
  alias Conveyor.Projects.{ApiKey, Project}
  alias ConveyorWeb.Format

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
    assign(socket, projects: projects, keys: keys, expiring: Projects.expiring_api_keys(14))
  end

  @impl true
  def handle_event("create_project", %{"project" => attrs}, socket) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
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
    {:ok, _} = id |> Projects.get_project!() |> Projects.archive_project()
    {:noreply, socket |> put_flash(:info, "Project archived") |> reload()}
  end

  def handle_event("create_key", %{"api_key" => attrs}, socket) do
    project = Projects.get_project!(attrs["project_id"])

    attrs =
      Map.update(attrs, "default_tags", %{}, &parse_tags/1) |> Map.put_new("scopes", ["ingest"])

    case Projects.create_api_key(project, attrs) do
      {:ok, key, plaintext} ->
        {:noreply,
         socket
         |> assign(
           new_key: %{key: key, plaintext: plaintext, project: project},
           key_form: to_form(ApiKey.changeset(%ApiKey{}, %{}))
         )
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, key_form: to_form(changeset))}
    end
  end

  def handle_event("rotate_key", %{"id" => id}, socket) do
    key = Projects.get_api_key!(id)
    {:ok, successor, plaintext} = Projects.rotate_api_key(key)
    project = Projects.get_project!(key.project_id)

    {:noreply,
     socket
     |> assign(new_key: %{key: successor, plaintext: plaintext, project: project})
     |> put_flash(:info, "Key rotated; the old key keeps working during the grace period")
     |> reload()}
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    {:ok, _} = id |> Projects.get_api_key!() |> Projects.revoke_api_key()
    {:noreply, socket |> put_flash(:info, "Key revoked") |> reload()}
  end

  def handle_event("dismiss_key", _params, socket), do: {:noreply, assign(socket, new_key: nil)}

  def handle_event("put_cache_endpoint", %{"endpoint" => attrs}, socket) do
    project = Projects.get_project!(attrs["project_id"])

    headers =
      if attrs["header_name"] in [nil, ""],
        do: %{},
        else: %{attrs["header_name"] => attrs["header_value"] || ""}

    case Projects.put_cache_endpoint(project, attrs["host"] || "", %{
           "headers" => headers,
           "tls" => attrs["tls"] == "true"
         }) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Cache endpoint saved") |> reload()}

      {:error, :invalid_host} ->
        {:noreply,
         put_flash(socket, :error, "Cache endpoint host must look like host or host:port")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the cache endpoint")}
    end
  end

  def handle_event("delete_cache_endpoint", %{"project_id" => project_id, "host" => host}, socket) do
    {:ok, _} = project_id |> Projects.get_project!() |> Projects.delete_cache_endpoint(host)
    {:noreply, socket |> put_flash(:info, "Cache endpoint removed") |> reload()}
  end

  # "ci=true, team=infra" → %{"ci" => "true", "team" => "infra"}
  defp parse_tags(string) when is_binary(string) do
    string
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [k, v] -> {String.trim(k), String.trim(v)} end)
  end

  defp parse_tags(other), do: other

  defp key_state(%ApiKey{revoked_at: %DateTime{}}), do: "revoked"

  defp key_state(%ApiKey{} = key),
    do: if(ApiKey.active?(key, DateTime.utc_now()), do: "active", else: "expired")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
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

      <div
        :if={@new_key}
        id="new-key"
        class="mb-4 rounded-md border border-emerald-500/40 bg-emerald-500/5 p-4"
      >
        <h2 class="text-sm font-semibold">Copy this key now: it will not be shown again</h2>
        <p class="mt-1 text-xs text-base-content/70">
          {@new_key.key.name} · project {@new_key.project.name}
        </p>
        <pre
          class="mt-2 select-all overflow-x-auto rounded bg-base-200 p-2 font-mono text-xs"
          id="new-key-plaintext"
        >{@new_key.plaintext}</pre>
        <pre class="mt-2 overflow-x-auto rounded bg-base-200 p-2 font-mono text-[11px] text-base-content/70">build --bes_backend=grpcs://your-host:1985 --bes_header=x-api-key={@new_key.plaintext} --bes_results_url=https://your-host/invocation/</pre>
        <button
          type="button"
          phx-click="dismiss_key"
          id="dismiss-key"
          class="mt-2 rounded border border-base-300 px-2 py-1 text-xs hover:bg-base-200"
        >Done</button>
      </div>

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

      <section
        :for={project <- @projects}
        id={"project-#{project.id}"}
        class="mb-4 rounded-md border border-base-300 p-4"
      >
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-semibold">
            {project.name} <span class="font-mono text-xs text-base-content/50">{project.slug}</span>
          </h2>
          <button
            :if={project.slug != "default"}
            type="button"
            phx-click="archive_project"
            phx-value-id={project.id}
            data-confirm="Archive this project? Its builds stay but no longer appear in the switcher."
            class="text-xs text-base-content/60 hover:underline"
          >Archive</button>
        </div>
        <table class="mt-2 w-full text-xs">
          <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/50">
            <tr>
              <th class="py-1 font-medium">Key</th><th class="py-1 font-medium">Id</th><th class="py-1 font-medium">
                Scopes
              </th><th class="py-1 font-medium">Tags</th><th class="py-1 font-medium">State</th><th class="py-1 font-medium">
                Last used
              </th><th></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/60">
            <tr :for={key <- @keys[project.id] || []} id={"key-#{key.id}"} data-state={key_state(key)}>
              <td class="py-1 font-medium">{key.name}</td>
              <td class="py-1 font-mono text-base-content/60">{key.key_id}</td>
              <td class="py-1">{Enum.join(key.scopes, ", ")}</td>
              <td class="py-1 font-mono">
                {Enum.map_join(key.default_tags, " ", fn {k, v} -> "#{k}=#{v}" end)}
              </td>
              <td class="py-1">
                {key_state(key)}<span
                  :if={key.expires_at && is_nil(key.revoked_at)}
                  class="text-base-content/50"
                > · expires {Format.relative(key.expires_at, DateTime.utc_now())}</span>
              </td>
              <td class="py-1 text-base-content/60">
                {if key.last_used_at,
                  do: Format.relative(key.last_used_at, DateTime.utc_now()),
                  else: "never"}
              </td>
              <td class="py-1 text-right whitespace-nowrap">
                <button
                  :if={is_nil(key.revoked_at)}
                  type="button"
                  phx-click="rotate_key"
                  phx-value-id={key.id}
                  class="mr-2 hover:underline"
                >Rotate</button>
                <button
                  :if={is_nil(key.revoked_at)}
                  type="button"
                  phx-click="revoke_key"
                  phx-value-id={key.id}
                  data-confirm="Revoke this key? Clients using it will be rejected immediately."
                  class="text-rose-600 hover:underline dark:text-rose-400"
                >Revoke</button>
              </td>
            </tr>
            <tr :if={(@keys[project.id] || []) == []}>
              <td colspan="7" class="py-2 text-base-content/50">No keys yet.</td>
            </tr>
          </tbody>
        </table>
        <.form
          for={@key_form}
          id={"key-form-#{project.id}"}
          phx-submit="create_key"
          class="mt-3 flex flex-wrap items-end gap-2"
        >
          <input type="hidden" name="api_key[project_id]" value={project.id} />
          <.input
            field={@key_form[:name]}
            id={"key-name-#{project.id}"}
            label="New key name"
            placeholder="github-actions"
          />
          <.input
            field={@key_form[:default_tags]}
            id={"key-tags-#{project.id}"}
            label="Default tags"
            placeholder="ci=true, team=infra"
            value=""
          />
          <.button variant="primary">Create key</.button>
        </.form>

        <div id={"cache-endpoints-#{project.id}"} class="mt-4 border-t border-base-300/60 pt-3">
          <h3 class="text-xs font-semibold">Remote cache endpoints</h3>
          <p class="text-[11px] text-base-content/60">
            Hosts Conveyor may contact to fetch profiles and test logs referenced as
            <code class="font-mono">bytestream://</code>
            URIs, with the headers your <code class="font-mono">--remote_header</code>
            flags carry. Nothing else is ever dialled.
          </p>
          <table :if={Projects.cache_endpoints(project) != %{}} class="mt-2 w-full text-xs">
            <tbody class="divide-y divide-base-300/60">
              <tr
                :for={{host, endpoint} <- Enum.sort(Projects.cache_endpoints(project))}
                id={"cache-endpoint-#{project.id}-#{String.replace(host, ~r/[^a-zA-Z0-9]/, "-")}"}
              >
                <td class="py-1 font-mono">{host}</td>
                <td class="py-1">{if endpoint["tls"], do: "TLS", else: "plaintext"}</td>
                <td class="py-1 font-mono text-base-content/60">
                  {Enum.map_join(endpoint["headers"] || %{}, " ", fn {k, _} -> "#{k}=••••" end)}
                </td>
                <td class="py-1 text-right">
                  <button
                    type="button"
                    phx-click="delete_cache_endpoint"
                    phx-value-project_id={project.id}
                    phx-value-host={host}
                    class="text-rose-600 hover:underline dark:text-rose-400"
                  >Remove</button>
                </td>
              </tr>
            </tbody>
          </table>
          <form
            id={"cache-endpoint-form-#{project.id}"}
            phx-submit="put_cache_endpoint"
            class="mt-2 flex flex-wrap items-end gap-2 text-xs"
          >
            <input type="hidden" name="endpoint[project_id]" value={project.id} />
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Host[:port]</span>
              <input
                name="endpoint[host]"
                placeholder="cache.example.com:443"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Header</span>
              <input
                name="endpoint[header_name]"
                placeholder="x-api-key"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Value</span>
              <input
                name="endpoint[header_value]"
                type="password"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex items-center gap-1 pb-1">
              <input type="checkbox" name="endpoint[tls]" value="true" checked /> TLS
            </label>
            <.button variant="primary">Save endpoint</.button>
          </form>
        </div>
      </section>

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
