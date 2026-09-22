defmodule Conveyor.Projects do
  @moduledoc "Projects and their API keys."
  import Ecto.Query

  alias Conveyor.Projects.{ApiKey, ApiKeyCache, Project}
  alias Conveyor.Repo

  @default_slug "default"
  @key_prefix "conveyor"

  # --- projects -------------------------------------------------------------------------

  @spec list_projects(keyword()) :: [Project.t()]
  def list_projects(opts \\ []) do
    query = from p in Project, order_by: p.name

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [p], is_nil(p.archived_at))

    Repo.all(query)
  end

  @spec get_project!(term()) :: Project.t()
  def get_project!(id), do: Repo.get!(Project, id)

  @spec get_project(term()) :: Project.t() | nil
  def get_project(id), do: Repo.get(Project, id)

  @doc "Restricts a project to members of these identity-provider groups (empty = everyone)."
  @spec put_allowed_groups(Project.t(), [String.t()]) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def put_allowed_groups(%Project{} = project, groups) do
    groups = groups |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    update_project(project, %{settings: Map.put(project.settings, "allowed_groups", groups)})
  end

  @spec allowed_groups(Project.t()) :: [String.t()]
  def allowed_groups(%Project{settings: settings}),
    do: Map.get(settings || %{}, "allowed_groups", [])

  @doc "Identity-provider groups whose members administer the project (keys, storage, endpoints, segments)."
  @spec put_admin_groups(Project.t(), [String.t()]) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def put_admin_groups(%Project{} = project, groups) do
    groups = groups |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    update_project(project, %{settings: Map.put(project.settings, "admin_groups", groups)})
  end

  @spec admin_groups(Project.t()) :: [String.t()]
  def admin_groups(%Project{settings: settings}), do: Map.get(settings || %{}, "admin_groups", [])

  @spec get_project_by_slug(String.t()) :: Project.t() | nil
  def get_project_by_slug(slug), do: Repo.get_by(Project, slug: slug)

  # --- storage settings: retention and blob prefix -------------------------------------

  @prefix_re ~r/^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$/
  @max_retention_days 3650

  @doc """
  Sets the project's retention (`"retention_days"`, blank = the global `RETENTION_DAYS`)
  and blob key prefix (`"blob_prefix"`, blank = the slug). Blobs already stored keep the
  prefix they were written under, so a change never orphans them.
  """
  @spec put_storage(Project.t(), map()) :: {:ok, Project.t()} | {:error, String.t()}
  def put_storage(%Project{} = project, attrs) do
    with {:ok, days} <- parse_retention(attrs["retention_days"]),
         {:ok, prefix} <- parse_prefix(attrs["blob_prefix"]) do
      settings =
        project.settings
        |> put_or_drop("retention_days", days)
        |> put_or_drop("blob_prefix", prefix)

      case update_project(project, %{settings: settings}) do
        {:ok, project} -> {:ok, project}
        {:error, changeset} -> {:error, inspect(changeset.errors)}
      end
    end
  end

  defp put_or_drop(settings, key, nil), do: Map.delete(settings, key)
  defp put_or_drop(settings, key, value), do: Map.put(settings, key, value)

  defp parse_retention(nil), do: {:ok, nil}

  defp parse_retention(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {days, ""} when days >= 1 and days <= @max_retention_days ->
            {:ok, days}

          _ ->
            {:error, "retention must be a whole number of days from 1 to #{@max_retention_days}"}
        end
    end
  end

  defp parse_prefix(nil), do: {:ok, nil}

  defp parse_prefix(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      p when byte_size(p) <= 64 ->
        if Regex.match?(@prefix_re, p), do: {:ok, p}, else: prefix_error()

      _ ->
        prefix_error()
    end
  end

  defp prefix_error,
    do: {:error, "blob prefix must be lowercase letters, digits, dots, dashes or underscores"}

  @doc "Days this project keeps builds, or nil for the global default."
  @spec retention_days(Project.t()) :: pos_integer() | nil
  def retention_days(%Project{settings: settings}), do: Map.get(settings || %{}, "retention_days")

  @doc """
  The key prefix a project's blobs are stored under (its slug unless overridden). Takes a
  project or a project id; blob writes call this once per blob.
  """
  @spec blob_prefix(Project.t() | integer()) :: String.t()
  def blob_prefix(%Project{slug: slug, settings: settings}),
    do: Map.get(settings || %{}, "blob_prefix") || slug

  def blob_prefix(project_id) when is_integer(project_id),
    do: project_id |> get_project!() |> blob_prefix()

  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs), do: %Project{} |> Project.changeset(attrs) |> Repo.insert()

  @spec update_project(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(project, attrs), do: project |> Project.changeset(attrs) |> Repo.update()

  @spec archive_project(Project.t()) :: {:ok, Project.t()}
  def archive_project(project) do
    project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update()
  end

  @doc "Returns the built-in default project, creating it on first use."
  @spec ensure_default_project!() :: Project.t()
  def ensure_default_project! do
    case get_project_by_slug(@default_slug) do
      nil ->
        Repo.insert!(%Project{slug: @default_slug, name: "Default"},
          on_conflict: :nothing,
          conflict_target: :slug
        )

        get_project_by_slug(@default_slug)

      project ->
        project
    end
  end

  # --- api keys -------------------------------------------------------------------------

  @spec list_api_keys(Project.t() | integer()) :: [ApiKey.t()]
  def list_api_keys(%Project{id: id}), do: list_api_keys(id)

  def list_api_keys(project_id) do
    Repo.all(
      from k in ApiKey, where: k.project_id == ^project_id, order_by: [desc: k.inserted_at]
    )
  end

  @spec get_api_key!(term()) :: ApiKey.t()
  def get_api_key!(id), do: Repo.get!(ApiKey, id)

  @doc """
  Creates a key and returns it together with the plaintext, which is never stored and
  cannot be recovered later.
  """
  @spec create_api_key(Project.t(), map()) ::
          {:ok, ApiKey.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_api_key(%Project{id: project_id}, attrs) do
    # base32 keeps the id free of the `_` separator used in the plaintext format
    key_id = 5 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    secret = random_token(32)

    changeset =
      %ApiKey{project_id: project_id, key_id: key_id, key_hash: hash(secret)}
      |> ApiKey.changeset(attrs)

    with {:ok, key} <- Repo.insert(changeset) do
      {:ok, key, plaintext(key_id, secret)}
    end
  end

  @doc """
  Rotates a key: creates a successor with the same name, scopes and tags, and gives the old
  key a grace expiry of `grace_days` (default 7) so both work while clients roll over.
  """
  @spec rotate_api_key(ApiKey.t(), keyword()) :: {:ok, ApiKey.t(), String.t()} | {:error, term()}
  def rotate_api_key(%ApiKey{} = key, opts \\ []) do
    grace_days =
      Keyword.get(opts, :grace_days, Application.get_env(:conveyor, :key_rotation_grace_days, 7))

    expires_at = DateTime.add(DateTime.utc_now(), grace_days * 24 * 3600, :second)

    Repo.transaction(fn ->
      project = get_project!(key.project_id)

      attrs = %{
        name: key.name,
        scopes: key.scopes,
        default_tags: key.default_tags,
        expires_at: key.expires_at,
        created_by: Keyword.get(opts, :created_by, key.created_by)
      }

      with {:ok, successor, plaintext} <- create_api_key(project, attrs),
           {:ok, successor} <-
             successor |> Ecto.Changeset.change(rotated_from_id: key.id) |> Repo.update(),
           {:ok, _old} <-
             key
             |> Ecto.Changeset.change(expires_at: earliest(key.expires_at, expires_at))
             |> Repo.update() do
        ApiKeyCache.invalidate(key.key_id)
        {successor, plaintext}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {successor, plaintext}} -> {:ok, successor, plaintext}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec revoke_api_key(ApiKey.t()) :: {:ok, ApiKey.t()}
  def revoke_api_key(%ApiKey{} = key) do
    result = key |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update()
    ApiKeyCache.invalidate(key.key_id)
    result
  end

  @doc """
  Verifies a plaintext key. Returns the key with its project preloaded when it is valid and
  active, otherwise `{:error, :malformed | :unknown | :revoked | :expired}`.
  Lookups are cached by key id; the secret is compared in constant time.
  """
  @spec verify_api_key(String.t()) ::
          {:ok, ApiKey.t()} | {:error, :malformed | :unknown | :revoked | :expired}
  def verify_api_key(plaintext) when is_binary(plaintext) do
    with {:ok, key_id, secret} <- parse(plaintext),
         %ApiKey{} = key <- ApiKeyCache.fetch(key_id, &load_key/1),
         true <- Plug.Crypto.secure_compare(key.key_hash, hash(secret)) do
      cond do
        key.revoked_at != nil -> {:error, :revoked}
        not ApiKey.active?(key, DateTime.utc_now()) -> {:error, :expired}
        true -> {:ok, key}
      end
    else
      nil -> {:error, :unknown}
      false -> {:error, :unknown}
      {:error, :malformed} -> {:error, :malformed}
    end
  end

  def verify_api_key(_), do: {:error, :malformed}

  @doc "Records key usage at most once per minute per key (cheap enough for the hot path)."
  @spec touch_api_key(ApiKey.t(), String.t() | nil) :: :ok
  def touch_api_key(%ApiKey{} = key, ip) do
    now = DateTime.utc_now()

    if key.last_used_at == nil or DateTime.diff(now, key.last_used_at, :second) > 60 do
      Repo.update_all(from(k in ApiKey, where: k.id == ^key.id),
        set: [last_used_at: now, last_used_ip: ip]
      )

      ApiKeyCache.invalidate(key.key_id)
    end

    :ok
  end

  @doc """
  Configures a remote cache endpoint (`host` or `host:port`) for artifact fetching:
  request headers (for example `x-api-key`) and whether to use TLS. Only configured
  hosts are ever contacted.
  """
  @spec put_cache_endpoint(Project.t(), String.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | :invalid_host}
  def put_cache_endpoint(%Project{} = project, host, attrs) do
    host = String.trim(host)
    endpoint_override = String.trim(attrs["endpoint"] || "")

    cond do
      not Regex.match?(~r/^[a-z0-9.\-]+(:\d{1,5})?$/i, host) ->
        {:error, :invalid_host}

      endpoint_override != "" and
          not Regex.match?(~r|^(grpcs?://)?[a-z0-9.\-]+(:\d{1,5})?$|i, endpoint_override) ->
        {:error, :invalid_endpoint}

      true ->
        headers =
          attrs
          |> Map.get("headers", %{})
          |> Enum.reject(fn {k, _} -> k == "" end)
          |> Map.new()

        endpoint =
          %{"headers" => headers, "tls" => normalize_tls(Map.get(attrs, "tls", false))}
          |> put_present("endpoint", endpoint_override)
          |> put_present("bearer_token", String.trim(attrs["bearer_token"] || ""))

        endpoints = Map.put(cache_endpoints(project), host, endpoint)

        update_project(project, %{
          settings: Map.put(project.settings, "cache_endpoints", endpoints)
        })
    end
  end

  # true/false stay booleans (system roots / plaintext); a map carries the mode and the
  # secret file paths for a custom CA or mTLS.
  defp normalize_tls(%{"mode" => mode} = tls) when mode in ~w(custom_ca mtls) do
    tls
    |> Map.take(~w(mode ca_file client_cert_file client_key_file))
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp normalize_tls(%{"mode" => "system_roots"}), do: true
  defp normalize_tls(%{"mode" => _}), do: false
  defp normalize_tls(value), do: value in [true, "true"]

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @spec delete_cache_endpoint(Project.t(), String.t()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete_cache_endpoint(%Project{} = project, host) do
    endpoints = Map.delete(cache_endpoints(project), host)
    update_project(project, %{settings: Map.put(project.settings, "cache_endpoints", endpoints)})
  end

  @spec cache_endpoints(Project.t()) :: %{String.t() => map()}
  def cache_endpoints(%Project{settings: settings}),
    do: Map.get(settings || %{}, "cache_endpoints", %{})

  @doc "Overrides the ingest limits of a key (see `Conveyor.Limits`)."
  @spec update_api_key_limits(ApiKey.t(), map()) ::
          {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def update_api_key_limits(%ApiKey{} = key, limits) do
    with {:ok, key} <- key |> ApiKey.changeset(%{limits: limits}) |> Repo.update() do
      ApiKeyCache.invalidate(key.key_id)
      {:ok, key}
    end
  end

  @doc "Keys expiring within `days` days (for the settings page and alerting)."
  @spec expiring_api_keys(pos_integer()) :: [ApiKey.t()]
  def expiring_api_keys(days \\ 7) do
    limit = DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)

    Repo.all(
      from k in ApiKey,
        where: is_nil(k.revoked_at) and not is_nil(k.expires_at) and k.expires_at <= ^limit,
        order_by: k.expires_at,
        preload: :project
    )
  end

  defp load_key(key_id) do
    Repo.one(from k in ApiKey, where: k.key_id == ^key_id, preload: :project)
  end

  @doc false
  def parse(@key_prefix <> "_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [key_id, secret] when byte_size(key_id) == 8 and byte_size(secret) > 0 ->
        {:ok, key_id, secret}

      _ ->
        {:error, :malformed}
    end
  end

  def parse(_), do: {:error, :malformed}

  defp plaintext(key_id, secret), do: "#{@key_prefix}_#{key_id}_#{secret}"
  defp hash(secret), do: :crypto.hash(:sha256, secret)

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp earliest(nil, b), do: b
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
