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

  @doc "Starts the fake cache; returns its port. Blobs are registered with `serve/2`."
  def start do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: __MODULE__)
    port = Conveyor.GrpcCase.free_port()

    {:ok, _} =
      GRPC.Server.Supervisor.start_link(endpoint: Endpoint, port: port, start_server: true)

    port
  end

  @doc "Serves `data` for the read resource `blobs/<hash>/<size>` (hash defaults to the real digest)."
  def serve(data, hash \\ nil) do
    hash = hash || Conveyor.Blobs.digest(data)
    resource = "blobs/#{hash}/#{byte_size(data)}"
    Agent.update(__MODULE__, &Map.put(&1, resource, data))
    resource
  end

  def headers, do: Agent.get(__MODULE__, &Map.get(&1, :headers, %{}))
end
