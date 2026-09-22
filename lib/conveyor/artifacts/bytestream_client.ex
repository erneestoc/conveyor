defmodule Conveyor.Artifacts.BytestreamClient do
  @moduledoc """
  Fetches a blob from a remote cache with `ByteStream.Read` and stores it in the blob
  store under the digest named by the resource, verifying the content on the way.
  """
  alias Conveyor.Artifacts.Resource
  alias Conveyor.Blobs
  alias Google.Bytestream.ByteStream.Stub
  alias Google.Bytestream.ReadRequest

  @doc """
  `endpoint` is the per-project cache endpoint configuration (see
  `Conveyor.Projects.put_cache_endpoint/3`): where to connect (`"endpoint"`, default the
  URI authority), how (`"tls"`: `false`/`"plaintext"`, `true`/`"system_roots"`, or a map
  with `"mode"` `custom_ca`/`mtls` and `ca_file`/`client_cert_file`/`client_key_file`), and
  which request metadata to send (`"headers"`, `"bearer_token"`). The URI never carries
  any of that: it is only a locator.
  """
  @spec fetch(map(), Resource.t(), keyword()) :: {:ok, Blobs.Blob.t()} | {:error, term()}
  def fetch(endpoint, %Resource{} = ref, opts \\ []) do
    {host, port} = target(endpoint, ref)

    with {:ok, ssl} <- ssl_options(endpoint, host),
         {:ok, channel} <- connect(host, port, ssl) do
      try do
        read(channel, ref, endpoint, opts)
      after
        GRPC.Stub.disconnect(channel)
      end
    end
  end

  @doc "Host and port to dial: the configured endpoint override, else the URI authority."
  def target(endpoint, %Resource{} = ref) do
    case endpoint["endpoint"] do
      value when is_binary(value) and value != "" ->
        {host, port} = split_host_port(String.replace(value, ~r{^grpcs?://}, ""))
        {host, port || default_port(endpoint)}

      _ ->
        {ref.host, ref.port || default_port(endpoint)}
    end
  end

  defp split_host_port(value) do
    case String.split(value, ":") do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, nil}
    end
  end

  defp default_port(endpoint), do: if(tls_mode(endpoint) == "plaintext", do: 80, else: 443)

  @doc "TLS mode: plaintext, system_roots, custom_ca or mtls."
  def tls_mode(endpoint) do
    case endpoint["tls"] do
      %{"mode" => mode} when mode in ~w(plaintext system_roots custom_ca mtls) -> mode
      true -> "system_roots"
      "system_roots" -> "system_roots"
      _ -> "plaintext"
    end
  end

  @doc "Erlang `:ssl` options for the endpoint, or `nil` for plaintext."
  @spec ssl_options(map(), String.t()) :: {:ok, keyword() | nil} | {:error, term()}
  def ssl_options(endpoint, host) do
    tls = if is_map(endpoint["tls"]), do: endpoint["tls"], else: %{}

    base = [
      verify: :verify_peer,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case tls_mode(endpoint) do
      "plaintext" ->
        {:ok, nil}

      "system_roots" ->
        {:ok, [{:cacerts, :public_key.cacerts_get()} | base]}

      "custom_ca" ->
        with {:ok, ca} <- file_opt(tls, "ca_file"), do: {:ok, [{:cacertfile, ca} | base]}

      "mtls" ->
        with {:ok, ca} <- file_opt(tls, "ca_file"),
             {:ok, cert} <- file_opt(tls, "client_cert_file"),
             {:ok, key} <- file_opt(tls, "client_key_file") do
          {:ok, [{:cacertfile, ca}, {:certfile, cert}, {:keyfile, key} | base]}
        end
    end
  end

  defp file_opt(tls, key) do
    case tls[key] do
      path when is_binary(path) and path != "" ->
        if File.regular?(path),
          do: {:ok, String.to_charlist(path)},
          else: {:error, {:tls_file_missing, key, path}}

      _ ->
        {:error, {:tls_file_missing, key, nil}}
    end
  end

  @doc "gRPC metadata for the endpoint: static headers plus an optional bearer token."
  def metadata(endpoint) do
    headers = Map.new(endpoint["headers"] || %{})

    case endpoint["bearer_token"] do
      token when is_binary(token) and token != "" ->
        Map.put(headers, "authorization", "Bearer " <> token)

      _ ->
        headers
    end
  end

  defp connect(host, port, nil), do: do_connect(host, port, adapter: GRPC.Client.Adapters.Mint)

  defp connect(host, port, ssl),
    do:
      do_connect(host, port,
        adapter: GRPC.Client.Adapters.Mint,
        cred: GRPC.Credential.new(ssl: ssl)
      )

  defp do_connect(host, port, opts) do
    case GRPC.Stub.connect("#{host}:#{port}", opts) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  defp read(channel, ref, endpoint, opts) do
    req = %ReadRequest{resource_name: ref.resource}
    metadata = metadata(endpoint)

    case Stub.read(channel, req,
           metadata: metadata,
           timeout: Keyword.get(opts, :timeout_ms, 300_000)
         ) do
      {:ok, replies} ->
        chunks =
          Stream.map(replies, fn
            {:ok, %{data: data}} -> data
            {:error, error} -> throw({:read_error, error})
            {:trailers, _} -> ""
          end)

        Blobs.put(Keyword.fetch!(opts, :project_id), chunks,
          digest: ref.hash,
          source: "fetch",
          content_type: Keyword.get(opts, :content_type)
        )

      {:error, error} ->
        {:error, rpc_error(error)}
    end
  catch
    {:read_error, error} -> {:error, rpc_error(error)}
    :exit, reason -> {:error, {:stream_closed, reason}}
  end

  @status_names %{
    1 => :cancelled,
    2 => :unknown,
    3 => :invalid_argument,
    4 => :deadline_exceeded,
    5 => :not_found,
    6 => :already_exists,
    7 => :permission_denied,
    8 => :resource_exhausted,
    9 => :failed_precondition,
    10 => :aborted,
    11 => :out_of_range,
    12 => :unimplemented,
    13 => :internal,
    14 => :unavailable,
    15 => :data_loss,
    16 => :unauthenticated
  }

  defp rpc_error(%GRPC.RPCError{status: status, message: message}),
    do: {:rpc, Map.get(@status_names, status, :unknown), message}

  defp rpc_error(other), do: other
end
