defmodule Google.Bytestream.ByteStream.Service do
  @moduledoc """
  `google.bytestream.ByteStream` service definition. The messages come from the
  `googleapis` package, which ships no service module, so it is declared here.
  """
  use GRPC.Service, name: "google.bytestream.ByteStream", protoc_gen_elixir_version: "0.17.0"

  rpc(:Read, Google.Bytestream.ReadRequest, stream(Google.Bytestream.ReadResponse))
  rpc(:Write, stream(Google.Bytestream.WriteRequest), Google.Bytestream.WriteResponse)

  rpc(
    :QueryWriteStatus,
    Google.Bytestream.QueryWriteStatusRequest,
    Google.Bytestream.QueryWriteStatusResponse
  )
end

defmodule Google.Bytestream.ByteStream.Stub do
  @moduledoc "Client stub for `google.bytestream.ByteStream`."
  use GRPC.Stub, service: Google.Bytestream.ByteStream.Service
end
