defmodule Conveyor.Grpc.AuthInterceptor do
  @moduledoc """
  Authenticates every BES call and attaches a `Conveyor.Ingest.Context` to the stream.

  In `:api_key` mode the request must carry `x-api-key: <key>` or
  `authorization: Bearer <key>`; the key decides the project. In `:none` mode every call
  lands in the default project (development / trusted networks).
  """
  @behaviour GRPC.Server.Interceptor

  alias Conveyor.Ingest.Context
  alias Conveyor.Projects

  @impl true
  def init(opts), do: opts

  @impl true
  def call(req, stream, next, _opts) do
    case authenticate(GRPC.Stream.get_headers(stream), scopes_for(stream.service_name)) do
      {:ok, ctx} ->
        next.(req, %{stream | local: Map.put(stream.local || %{}, :ctx, ctx)})

      {:error, status, message} ->
        raise GRPC.RPCError, status: status, message: message
    end
  end

  @bes_service "google.devtools.build.v1.PublishBuildEvent"

  @doc "Scopes that grant access to a gRPC service: BES needs `ingest`; the CAS sink accepts `upload` too."
  def scopes_for(@bes_service), do: ["ingest"]
  def scopes_for(_), do: ["ingest", "upload"]

  @doc "Builds the ingest context from request headers according to the configured auth mode."
  @spec authenticate(map(), [String.t()]) :: {:ok, Context.t()} | {:error, atom(), String.t()}
  def authenticate(headers, scopes \\ ["ingest"]) do
    case Conveyor.Ingest.config(:auth, :api_key) do
      :none ->
        project = default_project()

        {:ok,
         %Context{
           project_id: project.id,
           project_slug: project.slug,
           limits: Conveyor.Limits.defaults()
         }}

      :api_key ->
        with {:ok, plaintext} <- extract(headers),
             {:ok, key} <- Projects.verify_api_key(plaintext),
             true <- Enum.any?(scopes, &(&1 in key.scopes)) || {:error, :scope} do
          Projects.touch_api_key(key, nil)

          {:ok,
           %Context{
             project_id: key.project_id,
             project_slug: key.project.slug,
             api_key_id: key.id,
             api_key_tags: key.default_tags,
             limits: Conveyor.Limits.for_key(key)
           }}
        else
          {:error, :missing} ->
            {:error, :unauthenticated, "missing API key: pass --bes_header=x-api-key=<key>"}

          {:error, :malformed} ->
            {:error, :unauthenticated, "malformed API key"}

          {:error, :unknown} ->
            {:error, :unauthenticated, "unknown API key"}

          {:error, :revoked} ->
            {:error, :permission_denied, "API key has been revoked"}

          {:error, :expired} ->
            {:error, :permission_denied, "API key has expired"}

          {:error, :scope} ->
            {:error, :permission_denied, "API key lacks the #{Enum.join(scopes, " or ")} scope"}
        end
    end
  end

  defp extract(headers) do
    cond do
      is_binary(headers["x-api-key"]) and headers["x-api-key"] != "" ->
        {:ok, headers["x-api-key"]}

      match?("Bearer " <> _, headers["authorization"]) ->
        {:ok, String.trim_leading(headers["authorization"], "Bearer ")}

      match?("bearer " <> _, headers["authorization"]) ->
        {:ok, String.trim_leading(headers["authorization"], "bearer ")}

      true ->
        {:error, :missing}
    end
  end

  defp default_project do
    case :persistent_term.get({__MODULE__, :default_project}, nil) do
      nil ->
        project = Projects.ensure_default_project!()
        :persistent_term.put({__MODULE__, :default_project}, project)
        project

      project ->
        project
    end
  end
end
