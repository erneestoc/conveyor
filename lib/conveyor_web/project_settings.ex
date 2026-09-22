defmodule ConveyorWeb.ProjectSettings do
  @moduledoc """
  Events of the per-project settings section (`ConveyorWeb.ProjectSettingsComponents`),
  shared by the global Settings page and a project's own settings page. Every mutation
  authorizes against the project it targets, taken from the record, never from the form
  alone, so a project admin cannot reach another project by editing a hidden field.
  Callers reload their assigns after every event.
  """
  import Phoenix.Component, only: [assign: 3, to_form: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Conveyor.Accounts.Scope
  alias Conveyor.Audit
  alias Conveyor.Projects
  alias Conveyor.Projects.{ApiKey, Segments}

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("create_key", %{"api_key" => attrs}, socket) do
    project = authorize!(socket, attrs["project_id"])

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
         assign(socket, :new_key, %{key: key, plaintext: plaintext, project: project})
         |> assign(:key_form, to_form(ApiKey.changeset(%ApiKey{}, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :key_form, to_form(changeset))}
    end
  end

  def handle_event("rotate_key", %{"id" => id}, socket) do
    key = Projects.get_api_key!(id)
    project = authorize!(socket, key.project_id)
    {:ok, successor, plaintext} = Projects.rotate_api_key(key)

    audit(socket, "api_key.rotate",
      subject: {"api_key", key.key_id},
      project_id: project.id,
      metadata: %{"successor" => successor.key_id}
    )

    {:noreply,
     socket
     |> assign(:new_key, %{key: successor, plaintext: plaintext, project: project})
     |> put_flash(:info, "Key rotated; the old key keeps working during the grace period")}
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    key = Projects.get_api_key!(id)
    authorize!(socket, key.project_id)
    {:ok, key} = Projects.revoke_api_key(key)
    audit(socket, "api_key.revoke", subject: {"api_key", key.key_id}, project_id: key.project_id)
    {:noreply, put_flash(socket, :info, "Key revoked")}
  end

  def handle_event("dismiss_key", _params, socket), do: {:noreply, assign(socket, :new_key, nil)}

  def handle_event("put_cache_endpoint", %{"endpoint" => attrs}, socket) do
    project = authorize!(socket, attrs["project_id"])

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

        {:noreply, put_flash(socket, :info, "Cache endpoint saved")}

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

  def handle_event("delete_cache_endpoint", %{"project_id" => project_id, "host" => host}, socket) do
    {:ok, project} = socket |> authorize!(project_id) |> Projects.delete_cache_endpoint(host)

    audit(socket, "cache_endpoint.delete",
      subject: {"project", project.id},
      project_id: project.id,
      metadata: %{"host" => host}
    )

    {:noreply, put_flash(socket, :info, "Cache endpoint removed")}
  end

  # Who may see or manage a project is a global admin's decision.
  def handle_event(
        "put_allowed_groups",
        %{"project_id" => project_id, "groups" => groups},
        socket
      ) do
    {:ok, project} =
      socket
      |> authorize_global!(project_id)
      |> Projects.put_allowed_groups(String.split(groups || "", ","))

    audit(socket, "project.allowed_groups",
      subject: {"project", project.id},
      project_id: project.id,
      metadata: %{"groups" => Projects.allowed_groups(project)}
    )

    {:noreply, put_flash(socket, :info, "Project access updated")}
  end

  def handle_event("put_admin_groups", %{"project_id" => project_id, "groups" => groups}, socket) do
    {:ok, project} =
      socket
      |> authorize_global!(project_id)
      |> Projects.put_admin_groups(String.split(groups || "", ","))

    audit(socket, "project.admin_groups",
      subject: {"project", project.id},
      project_id: project.id,
      metadata: %{"groups" => Projects.admin_groups(project)}
    )

    {:noreply, put_flash(socket, :info, "Project admins updated")}
  end

  def handle_event("put_storage", %{"project_id" => project_id} = params, socket) do
    project = authorize!(socket, project_id)

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

        {:noreply, put_flash(socket, :info, "Storage settings updated")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("create_segment", %{"segment" => attrs}, socket) do
    project = authorize!(socket, attrs["project_id"])

    case Segments.create(project, attrs) do
      {:ok, segment} ->
        audit(socket, "segment.create",
          subject: {"segment", segment.id},
          project_id: project.id,
          metadata: %{"name" => segment.name, "query" => segment.query}
        )

        {:noreply, put_flash(socket, :info, "Segment #{segment.name} saved")}

      {:error, changeset} ->
        message =
          Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, put_flash(socket, :error, "Could not save the segment: #{message}")}
    end
  end

  def handle_event("delete_segment", %{"id" => id}, socket) do
    segment = Segments.get!(id)
    authorize!(socket, segment.project_id)
    {:ok, segment} = Segments.delete(segment)

    audit(socket, "segment.delete",
      subject: {"segment", segment.id},
      project_id: segment.project_id,
      metadata: %{"name" => segment.name}
    )

    {:noreply, put_flash(socket, :info, "Segment removed")}
  end

  def handle_event("move_segment", %{"id" => id, "dir" => dir}, socket) do
    segment = Segments.get!(id)
    authorize!(socket, segment.project_id)
    :ok = Segments.move(segment, if(dir == "up", do: :up, else: :down))
    {:noreply, socket}
  end

  @doc "The project, when the scope may administer it; raises `ConveyorWeb.NotFoundError` otherwise."
  @spec authorize!(Phoenix.LiveView.Socket.t(), term()) :: Projects.Project.t()
  def authorize!(%{assigns: %{current_scope: scope}}, project_id) do
    project = Projects.get_project(project_id)

    if project && Scope.can_admin_project?(scope, project),
      do: project,
      else: raise(ConveyorWeb.NotFoundError, "no project #{inspect(project_id)}")
  end

  defp authorize_global!(%{assigns: %{current_scope: %Scope{admin?: true}}}, project_id),
    do: Projects.get_project!(project_id)

  defp authorize_global!(_socket, project_id),
    do: raise(ConveyorWeb.NotFoundError, "no project #{inspect(project_id)}")

  @doc false
  def audit(socket, action, opts), do: Audit.log(socket.assigns.current_scope, action, opts)

  # "ci=true, team=infra" → %{"ci" => "true", "team" => "infra"}
  defp parse_tags(string) when is_binary(string) do
    string
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Map.new(fn [k, v] -> {String.trim(k), String.trim(v)} end)
  end

  defp parse_tags(other), do: other
end
