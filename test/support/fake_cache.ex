defmodule Conveyor.FakeCache do
  @moduledoc """
  A stand-in remote cache for tests: a ByteStream server on its own gRPC endpoint that
  serves blobs from an Agent and records the request headers it saw. Content is served
  verbatim, so a test can register wrong bytes under a digest to exercise verification.
  """

  defmodule Interceptor do
    @behaviour GRPC.Server.Interceptor
    def init(opts), do: opts

    def call(req, stream, next, _opts) do
      headers = GRPC.Stream.get_headers(stream)
      Agent.update(Conveyor.FakeCache, &Map.put(&1, :headers, headers))
      next.(req, stream)
    end
  end

  defmodule Server do
    use GRPC.Server, service: Google.Bytestream.ByteStream.Service
    alias Google.Bytestream, as: BS

    def read(%BS.ReadRequest{resource_name: name}, stream) do
      case Agent.get(Conveyor.FakeCache, &Map.get(&1, name)) do
        nil ->
          raise GRPC.RPCError, status: :not_found, message: "no #{name}"

        data ->
          data
          |> chunk(3)
          |> Enum.each(&GRPC.Server.send_reply(stream, %BS.ReadResponse{data: &1}))

          :ok
      end
    end

    def write(_requests, _stream),
      do: raise(GRPC.RPCError, status: :unimplemented, message: "read-only")

    def query_write_status(_req, _stream),
      do: raise(GRPC.RPCError, status: :unimplemented, message: "read-only")

    defp chunk("", _), do: []
    defp chunk(bin, n) when byte_size(bin) <= n, do: [bin]

    defp chunk(bin, n),
      do: [binary_part(bin, 0, n) | chunk(binary_part(bin, n, byte_size(bin) - n), n)]
  end

  defmodule Endpoint do
    use GRPC.Endpoint
    intercept Conveyor.FakeCache.Interceptor
    run(Conveyor.FakeCache.Server)
  end

  @doc """
  Starts the fake cache; returns its port. `tls: [certfile:, keyfile:, cacertfile:]` starts
  it with TLS requiring a client certificate (mTLS), like a NativeLink listener.
  """
  def start(opts \\ []) do
    unless Process.whereis(__MODULE__),
      do: {:ok, _} = Agent.start_link(fn -> %{} end, name: __MODULE__)

    port = Conveyor.GrpcCase.free_port()

    server_opts =
      case Keyword.get(opts, :tls) do
        nil ->
          []

        ssl ->
          [
            adapter_opts: [
              cred:
                GRPC.Credential.new(
                  ssl: ssl ++ [verify: :verify_peer, fail_if_no_peer_cert: true]
                )
            ]
          ]
      end

    {:ok, _} =
      GRPC.Server.Supervisor.start_link(
        [endpoint: Endpoint, port: port, start_server: true] ++ server_opts
      )

    port
  end

  @doc "Writes an OTP-generated CA, server and client certificate set to PEM files."
  def test_certs(dir) do
    File.mkdir_p!(dir)

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65537}, extensions: [san()]]
        },
        client_chain: %{
          root: [key: {:rsa, 2048, 65537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65537}]
        }
      })

    write = fn name, entries ->
      path = Path.join(dir, name)
      File.write!(path, :public_key.pem_encode(entries))
      path
    end

    key_entry = fn {type, der} -> {type, der, :not_encrypted} end

    %{
      server_cert: write.("server.crt", [{:Certificate, server[:cert], :not_encrypted}]),
      server_key: write.("server.key", [key_entry.(server[:key])]),
      server_ca:
        write.("server-ca.crt", Enum.map(server[:cacerts], &{:Certificate, &1, :not_encrypted})),
      client_cert: write.("client.crt", [{:Certificate, client[:cert], :not_encrypted}]),
      client_key: write.("client.key", [key_entry.(client[:key])]),
      client_ca:
        write.("client-ca.crt", Enum.map(client[:cacerts], &{:Certificate, &1, :not_encrypted}))
    }
  end

  defp san, do: {:Extension, {2, 5, 29, 17}, false, [iPAddress: <<127, 0, 0, 1>>]}

  @doc "Serves `data` for the read resource `blobs/<hash>/<size>` (hash defaults to the real digest)."
  def serve(data, hash \\ nil) do
    hash = hash || Conveyor.Blobs.digest(data)
    resource = "blobs/#{hash}/#{byte_size(data)}"
    Agent.update(__MODULE__, &Map.put(&1, resource, data))
    resource
  end

  def headers, do: Agent.get(__MODULE__, &Map.get(&1, :headers, %{}))
end
