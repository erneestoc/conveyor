defmodule Conveyor.Artifacts do
  @moduledoc """
  Files referenced by or attached to an invocation: the JSON profile, test logs and
  XML reports, action outputs, and anything uploaded through the HTTP API.

  `fetch/2` resolves a BEP file map (`%{"name", "uri", "digest", ...}`) to a blob digest:
  blobs already in the store (uploaded, or received by the built-in CAS sink) are served
  directly; `bytestream://` URIs are fetched from the remote cache named by the URI, but
  only when that host is configured as a cache endpoint of the invocation's project. The
  configured endpoints are the allow-list: nothing else is ever dialled.
  """
  import Ecto.Query
  require Logger

  alias Conveyor.Artifacts.{BytestreamClient, Resource}
  alias Conveyor.Blobs
  alias Conveyor.Invocations.{Artifact, Invocation}
  alias Conveyor.Projects
  alias Conveyor.Repo

  @type fetch_error ::
          :local_file
          | :unsupported_scheme
          | :invalid_resource
          | :unsupported_digest
          | :endpoint_not_configured
          | :too_large
          | :no_uri
          | term()

  @doc "Configuration knob under `config :conveyor, Conveyor.Artifacts`."
  def config(key, default \\ nil),
    do: Application.get_env(:conveyor, __MODULE__, []) |> Keyword.get(key, default)

  @doc "Resolves a BEP file map to a blob digest, fetching it from the remote cache if needed."
  @spec fetch(Invocation.t(), map() | nil) :: {:ok, Blobs.digest()} | {:error, fetch_error()}
  def fetch(%Invocation{} = inv, %{"uri" => uri} = file) when is_binary(uri) do
    with {:ok, ref} <- Resource.parse_uri(uri) do
      cond do
        Blobs.exists?(ref.hash) ->
          {:ok, ref.hash}

        ref.size > config(:max_bytes, 512 * 1024 * 1024) ->
          {:error, :too_large}

        true ->
          fetch_remote(inv, ref, content_type(file["name"]))
      end
    end
  end

  def fetch(%Invocation{}, %{"contents" => contents}) when is_binary(contents) do
    with {:ok, blob} <- Blobs.put(contents, source: "fetch") do
      {:ok, blob.digest}
    end
  end

  def fetch(%Invocation{}, _), do: {:error, :no_uri}

  defp fetch_remote(inv, ref, content_type) do
    project = Projects.get_project!(inv.project_id)

    case endpoint_for(project, ref) do
      nil ->
        {:error, :endpoint_not_configured}

      endpoint ->
        with {:ok, blob} <- BytestreamClient.fetch(endpoint, ref, content_type: content_type) do
          {:ok, blob.digest}
        end
    end
  end

  @doc "The cache endpoint configured for the URI's host, or nil (the SSRF allow-list)."
  @spec endpoint_for(Projects.Project.t(), Resource.t()) :: map() | nil
  def endpoint_for(%{settings: settings}, %Resource{} = ref) do
    endpoints = Map.get(settings || %{}, "cache_endpoints", %{})
    endpoints[Resource.authority(ref)] || endpoints[ref.host]
  end

  @doc "Content type guessed from a file name."
  @spec content_type(String.t() | nil) :: String.t()
  def content_type(name) when is_binary(name) do
    cond do
      String.ends_with?(name, ".gz") -> "application/gzip"
      String.ends_with?(name, ".json") -> "application/json"
      String.ends_with?(name, ".xml") -> "application/xml"
      String.ends_with?(name, [".log", ".txt", ".out", ".err"]) -> "text/plain"
      true -> "application/octet-stream"
    end
  end

  def content_type(_), do: "application/octet-stream"

  @doc "Named artifacts attached to an invocation."
  @spec list(Invocation.t() | String.t()) :: [Artifact.t()]
  def list(inv),
    do: Repo.all(from a in Artifact, where: a.invocation_id == ^id(inv), order_by: a.name)

  @spec get(Invocation.t() | String.t(), String.t()) :: Artifact.t() | nil
  def get(inv, name), do: Repo.get_by(Artifact, invocation_id: id(inv), name: name)

  @doc "Attaches a blob to an invocation under a name (replacing a previous file of that name)."
  @spec attach(Invocation.t() | String.t(), String.t(), Blobs.Blob.t(), String.t()) ::
          Artifact.t()
  def attach(inv, name, %Blobs.Blob{} = blob, source) do
    Blobs.pin(blob.digest)
    now = DateTime.utc_now()

    row = %{
      invocation_id: id(inv),
      name: name,
      digest: blob.digest,
      size: blob.size,
      content_type: blob.content_type,
      source: source,
      inserted_at: now
    }

    {1, [artifact]} =
      Repo.insert_all(Artifact, [row],
        on_conflict: {:replace, [:digest, :size, :content_type, :source, :inserted_at]},
        conflict_target: [:invocation_id, :name],
        returning: true
      )

    artifact
  end

  @profile_names ~w(command.profile.gz command.profile.json)

  @doc "True when an artifact name is a Bazel JSON profile."
  @spec profile_name?(String.t()) :: boolean()
  def profile_name?(name),
    do: name in @profile_names or String.ends_with?(name, [".profile.gz", ".profile.json"])

  @doc """
  Called when an invocation is finalized: schedules the profile fetch when the build
  referenced a profile on a remote cache, or marks it available if the blob is already
  here (built-in CAS sink).
  """
  @spec on_finalized(String.t()) :: :ok
  def on_finalized(invocation_id) do
    case Repo.get(Invocation, invocation_id) do
      %Invocation{profile_status: "referenced", profile_uri: uri} = inv when is_binary(uri) ->
        case Resource.parse_uri(uri) do
          {:ok, %Resource{hash: hash}} ->
            if Blobs.exists?(hash),
              do: profile_available(inv, Blobs.get(hash)),
              else: enqueue_profile_fetch(inv)

          {:error, reason} ->
            set_profile_status(inv, "unavailable", reason)
        end

      _ ->
        :ok
    end

    :ok
  end

  defp enqueue_profile_fetch(inv) do
    %{invocation_id: inv.id}
    |> Conveyor.Workers.FetchProfile.new()
    |> Oban.insert()

    :ok
  end

  @doc """
  Fetches the referenced profile now. Returns `:ok`, `{:unavailable, reason}` for a
  permanent condition (no endpoint, local file) or `{:error, reason}` for a retryable one.
  """
  @spec fetch_profile(Invocation.t()) :: :ok | {:unavailable, term()} | {:error, term()}
  def fetch_profile(%Invocation{profile_uri: uri} = inv) when is_binary(uri) do
    name = uri |> String.split("/") |> List.last()
    name = if profile_name?(name), do: name, else: "command.profile.gz"

    case fetch(inv, %{"uri" => uri, "name" => name}) do
      {:ok, digest} ->
        profile_available(inv, Blobs.get(digest))
        :ok

      {:error, reason}
      when reason in [
             :local_file,
             :endpoint_not_configured,
             :too_large,
             :unsupported_scheme,
             :invalid_resource,
             :unsupported_digest
           ] ->
        set_profile_status(inv, "unavailable", reason)
        {:unavailable, reason}

      {:error, {:rpc, :not_found, _} = reason} ->
        set_profile_status(inv, "unavailable", reason)
        {:unavailable, reason}

      {:error, reason} ->
        set_profile_status(inv, "failed", reason)
        {:error, reason}
    end
  end

  def fetch_profile(%Invocation{}), do: {:unavailable, :no_uri}

  @doc "Records a profile blob as the invocation's profile and attaches it by name."
  @spec profile_available(Invocation.t(), Blobs.Blob.t(), String.t()) :: :ok
  def profile_available(%Invocation{} = inv, %Blobs.Blob{} = blob, name \\ "command.profile.gz") do
    attach(inv, name, blob, blob.source)

    Repo.update_all(from(i in Invocation, where: i.id == ^inv.id),
      set: [profile_blob: blob.digest, profile_status: "available"]
    )

    %{invocation_id: inv.id} |> Conveyor.Workers.ProfileSummary.new() |> Oban.insert()

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Conveyor.Ingest.invocation_topic(inv.id),
      {:artifacts_changed, inv.id}
    )

    :ok
  end

  defp set_profile_status(inv, status, reason) do
    Logger.info("invocation #{inv.id}: profile #{status}: #{inspect(reason)}")
    Repo.update_all(from(i in Invocation, where: i.id == ^inv.id), set: [profile_status: status])
    :ok
  end

  defp id(%Invocation{id: id}), do: id
  defp id(id) when is_binary(id), do: id
end
