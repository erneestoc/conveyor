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

  def handle_event("create_key", %{"api_key" => attrs}, socket) do
    project = Projects.get_project!(attrs["project_id"])

    attrs =
      Map.update(attrs, "default_tags", %{}, &parse_tags/1) |> Map.put_new("scopes", ["ingest"])

    case Projects.create_api_key(project, attrs) do
      {:ok, key, plaintext} ->
        audit(socket, "api_key.create",
          subject: {"api_key", key.key_id},
          project_id: project.id,
          metadata: %{"name" => key.name, "scopes" => key.scopes}
        )

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

    audit(socket, "api_key.rotate",
      subject: {"api_key", key.key_id},
      project_id: project.id,
      metadata: %{"successor" => successor.key_id}
    )

    {:noreply,
     socket
     |> assign(new_key: %{key: successor, plaintext: plaintext, project: project})
     |> put_flash(:info, "Key rotated; the old key keeps working during the grace period")
     |> reload()}
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    {:ok, key} = id |> Projects.get_api_key!() |> Projects.revoke_api_key()
    audit(socket, "api_key.revoke", subject: {"api_key", key.key_id}, project_id: key.project_id)
    {:noreply, socket |> put_flash(:info, "Key revoked") |> reload()}
  end

  def handle_event("dismiss_key", _params, socket), do: {:noreply, assign(socket, new_key: nil)}

  def handle_event("put_cache_endpoint", %{"endpoint" => attrs}, socket) do
    project = Projects.get_project!(attrs["project_id"])

    headers =
      if attrs["header_name"] in [nil, ""],
        do: %{},
        else: %{attrs["header_name"] => attrs["header_value"] || ""}

    tls =
      Map.merge(
        %{"mode" => attrs["tls_mode"] || "system_roots"},
        Map.take(attrs, ~w(ca_file client_cert_file client_key_file))
      )

    case Projects.put_cache_endpoint(project, attrs["host"] || "", %{
           "headers" => headers,
           "tls" => tls,
           "endpoint" => attrs["endpoint"],
           "bearer_token" => attrs["bearer_token"]
         }) do
      {:ok, _} ->
        audit(socket, "cache_endpoint.put",
          subject: {"project", project.id},
          project_id: project.id,
          metadata: %{"host" => attrs["host"], "headers" => Map.keys(headers)}
        )

        {:noreply, socket |> put_flash(:info, "Cache endpoint saved") |> reload()}

      {:error, :invalid_host} ->
        {:noreply,
         put_flash(socket, :error, "Cache endpoint host must look like host or host:port")}

      {:error, :invalid_endpoint} ->
        {:noreply,
         put_flash(socket, :error, "Endpoint override must look like [grpcs://]host[:port]")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the cache endpoint")}
    end
  end

  def handle_event(
        "put_allowed_groups",
        %{"project_id" => project_id, "groups" => groups},
        socket
      ) do
    {:ok, project} =
      project_id
      |> Projects.get_project!()
      |> Projects.put_allowed_groups(String.split(groups || "", ","))

    audit(socket, "project.allowed_groups",
      subject: {"project", project.id},
      project_id: project.id,
      metadata: %{"groups" => Projects.allowed_groups(project)}
    )

    {:noreply, socket |> put_flash(:info, "Project access updated") |> reload()}
  end

  def handle_event("put_storage", %{"project_id" => project_id} = params, socket) do
    project = Projects.get_project!(project_id)

    case Projects.put_storage(project, Map.take(params, ["retention_days", "blob_prefix"])) do
      {:ok, project} ->
        audit(socket, "project.storage",
          subject: {"project", project.id},
          project_id: project.id,
          metadata: %{
            "retention_days" => Projects.retention_days(project),
            "blob_prefix" => Projects.blob_prefix(project)
          }
        )

        {:noreply, socket |> put_flash(:info, "Storage settings updated") |> reload()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_cache_endpoint", %{"project_id" => project_id, "host" => host}, socket) do
    {:ok, project} = project_id |> Projects.get_project!() |> Projects.delete_cache_endpoint(host)

    audit(socket, "cache_endpoint.delete",
      subject: {"project", project.id},
      project_id: project.id,
      metadata: %{"host" => host}
    )

    {:noreply, socket |> put_flash(:info, "Cache endpoint removed") |> reload()}
  end

  def handle_event("create_segment", %{"segment" => attrs}, socket) do
    project = Projects.get_project!(attrs["project_id"])

    case Segments.create(project, attrs) do
      {:ok, segment} ->
        audit(socket, "segment.create",
          subject: {"segment", segment.id},
          project_id: project.id,
          metadata: %{"name" => segment.name, "query" => segment.query}
        )

        {:noreply, socket |> put_flash(:info, "Segment #{segment.name} saved") |> reload()}

      {:error, changeset} ->
        message =
          Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, put_flash(socket, :error, "Could not save the segment: #{message}")}
    end
  end

  def handle_event("delete_segment", %{"id" => id}, socket) do
    {:ok, segment} = id |> Segments.get!() |> Segments.delete()

    audit(socket, "segment.delete",
      subject: {"segment", segment.id},
      project_id: segment.project_id,
      metadata: %{"name" => segment.name}
    )

    {:noreply, socket |> put_flash(:info, "Segment removed") |> reload()}
  end

  def handle_event("move_segment", %{"id" => id, "dir" => dir}, socket) do
    :ok = id |> Segments.get!() |> Segments.move(if(dir == "up", do: :up, else: :down))
    {:noreply, reload(socket)}
  end

  defp audit(socket, action, opts), do: Audit.log(socket.assigns.current_scope, action, opts)

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

        <form
          id={"allowed-groups-form-#{project.id}"}
          phx-submit="put_allowed_groups"
          class="mt-4 flex flex-wrap items-end gap-2 border-t border-base-300/60 pt-3 text-xs"
        >
          <input type="hidden" name="project_id" value={project.id} />
          <label class="flex flex-col gap-1">
            <span class="text-[11px] text-base-content/60">
              Visible to identity-provider groups (comma-separated; empty = everyone; admins always see it)
            </span>
            <input
              name="groups"
              value={Enum.join(Projects.allowed_groups(project), ", ")}
              placeholder="team-payments, platform"
              class="w-96 rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
            />
          </label>
          <.button variant="primary">Save access</.button>
        </form>

        <form
          id={"storage-form-#{project.id}"}
          phx-submit="put_storage"
          class="mt-4 flex flex-wrap items-end gap-2 border-t border-base-300/60 pt-3 text-xs"
        >
          <input type="hidden" name="project_id" value={project.id} />
          <label class="flex flex-col gap-1">
            <span class="text-[11px] text-base-content/60">
              Keep builds for (days; empty = server default {Application.get_env(
                :conveyor,
                :retention_days,
                90
              )})
            </span>
            <input
              name="retention_days"
              type="number"
              min="1"
              max="3650"
              value={Projects.retention_days(project)}
              placeholder={Application.get_env(:conveyor, :retention_days, 90)}
              class="w-32 rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-[11px] text-base-content/60">
              Blob key prefix (profiles, logs and cache uploads live under it; empty = slug)
            </span>
            <input
              name="blob_prefix"
              value={project.settings["blob_prefix"]}
              placeholder={project.slug}
              class="w-64 rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
            />
          </label>
          <.button variant="primary">Save storage</.button>
        </form>

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
                <td class="py-1">
                  {Conveyor.Artifacts.BytestreamClient.tls_mode(endpoint)}{if endpoint["endpoint"],
                    do: " → #{endpoint["endpoint"]}"}
                </td>
                <td class="py-1 font-mono text-base-content/60">
                  {Enum.map_join(endpoint["headers"] || %{}, " ", fn {k, _} -> "#{k}=••••" end)}{if endpoint[
                                                                                                      "bearer_token"
                                                                                                    ],
                                                                                                    do:
                                                                                                      " bearer=••••"}
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
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Bearer token (optional)</span>
              <input
                name="endpoint[bearer_token]"
                type="password"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Connect to (optional override)</span>
              <input
                name="endpoint[endpoint]"
                placeholder="grpcs://cas.internal:443"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">TLS</span>
              <select
                name="endpoint[tls_mode]"
                class="rounded border border-base-300 bg-base-100 px-2 py-1"
              >
                <option value="system_roots">system roots</option>
                <option value="custom_ca">custom CA</option>
                <option value="mtls">mTLS (client certificate)</option>
                <option value="plaintext">plaintext</option>
              </select>
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">CA file (custom CA / mTLS)</span>
              <input
                name="endpoint[ca_file]"
                placeholder="/etc/conveyor/secrets/cas-ca.crt"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Client cert file (mTLS)</span>
              <input
                name="endpoint[client_cert_file]"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Client key file (mTLS)</span>
              <input
                name="endpoint[client_key_file]"
                class="rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <.button variant="primary">Save endpoint</.button>
          </form>
        </div>
        <div class="mt-3" id={"segments-#{project.id}"}>
          <h3 class="text-xs font-semibold">Dashboard segments</h3>
          <p class="text-[11px] text-base-content/50">
            Named queries the dashboard splits and compares by. Without any, the defaults are
            Local (<code>ci!=true</code>) and CI (<code>ci:true</code>).
          </p>
          <table class="mt-1 w-full text-xs">
            <tbody class="divide-y divide-base-300/60">
              <tr :for={seg <- @segments[project.id] || []} id={"segment-row-#{seg.id}"}>
                <td class="py-1 font-medium">{seg.name}</td>
                <td class="py-1 font-mono text-base-content/70">{seg.query}</td>
                <td class="py-1 text-right whitespace-nowrap">
                  <button
                    type="button"
                    phx-click="move_segment"
                    phx-value-id={seg.id}
                    phx-value-dir="up"
                    title="Move up"
                    class="mr-1 hover:underline"
                  >↑</button>
                  <button
                    type="button"
                    phx-click="move_segment"
                    phx-value-id={seg.id}
                    phx-value-dir="down"
                    title="Move down"
                    class="mr-2 hover:underline"
                  >↓</button>
                  <button
                    type="button"
                    phx-click="delete_segment"
                    phx-value-id={seg.id}
                    class="text-rose-600 hover:underline dark:text-rose-400"
                  >Remove</button>
                </td>
              </tr>
              <tr :if={(@segments[project.id] || []) == []}>
                <td colspan="3" class="py-1 text-base-content/50">Using the default segments.</td>
              </tr>
            </tbody>
          </table>
          <form
            id={"segment-form-#{project.id}"}
            phx-submit="create_segment"
            class="mt-2 flex flex-wrap items-end gap-2 text-xs"
          >
            <input type="hidden" name="segment[project_id]" value={project.id} />
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Name</span>
              <input
                name="segment[name]"
                placeholder="Main branch CI"
                class="rounded border border-base-300 bg-base-100 px-2 py-1"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-[11px] text-base-content/60">Query</span>
              <input
                name="segment[query]"
                placeholder="ci:true branch:main"
                class="w-64 rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
              />
            </label>
            <.button variant="primary">Add segment</.button>
          </form>
        </div>
      </section>

      <section id="audit-log" class="mb-4 rounded-md border border-base-300 p-4">
        <h2 class="text-sm font-semibold">Audit log</h2>
        <p class="text-[11px] text-base-content/60">
          Sign-ins, key and project changes, uploads. Latest 50.
        </p>
        <table class="mt-2 w-full text-xs">
          <tbody class="divide-y divide-base-300/60">
            <tr :for={e <- @audit} id={"audit-#{e.id}"}>
              <td class="py-1 whitespace-nowrap text-base-content/60">
                {Format.relative(e.inserted_at, DateTime.utc_now())}
              </td>
              <td class="py-1 font-mono">{e.actor}</td>
              <td class="py-1 font-mono font-medium">{e.action}</td>
              <td class="py-1 font-mono text-base-content/70">
                {e.subject_type}{if e.subject_id, do: " #{e.subject_id}"}
              </td>
              <td class="py-1 font-mono text-base-content/50">
                {if e.metadata != %{}, do: Jason.encode!(e.metadata)}
              </td>
            </tr>
            <tr :if={@audit == []}>
              <td class="py-2 text-base-content/50">Nothing yet.</td>
            </tr>
          </tbody>
        </table>
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
