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
  `endpoint` is the per-project cache endpoint configuration:
  `%{"headers" => %{name => value}, "tls" => boolean}`.
  Returns `{:ok, blob}` or `{:error, reason}`.
  """
  @spec fetch(map(), Resource.t(), keyword()) :: {:ok, Blobs.Blob.t()} | {:error, term()}
  def fetch(endpoint, %Resource{} = ref, opts \\ []) do
    port = ref.port || if(endpoint["tls"], do: 443, else: 80)

    with {:ok, channel} <- connect(ref.host, port, endpoint) do
      try do
        read(channel, ref, endpoint, opts)
      after
        GRPC.Stub.disconnect(channel)
      end
    end
  end

  defp connect(host, port, endpoint) do
    opts = [adapter: GRPC.Client.Adapters.Mint]

    opts =
      if endpoint["tls"] do
        [
          {:cred,
           GRPC.Credential.new(
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: String.to_charlist(host),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ]
           )}
          | opts
        ]
      else
        opts
      end

    case GRPC.Stub.connect("#{host}:#{port}", opts) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  defp read(channel, ref, endpoint, opts) do
    req = %ReadRequest{resource_name: ref.resource}
    metadata = Map.new(endpoint["headers"] || %{})

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

        Blobs.put(chunks,
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

  defp rpc_error(%GRPC.RPCError{status: status, message: message}) do
    name = status |> GRPC.Status.code_name() |> Macro.underscore() |> String.to_atom()
    {:rpc, name, message}
  end

  defp rpc_error(other), do: other
end
