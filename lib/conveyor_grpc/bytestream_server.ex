defmodule Conveyor.Grpc.ByteStreamServer do
  @moduledoc """
  `google.bytestream.ByteStream` over the blob store.

  `Read` serves any blob Conveyor holds (profiles, uploads). `Write` and
  `QueryWriteStatus` are the upload half of the built-in CAS sink and are only enabled
  with `CAS_SINK_ENABLED=true`; uploaded blobs expire after `CAS_TTL_DAYS` unless an
  invocation references them.
  """
  use GRPC.Server, service: Google.Bytestream.ByteStream.Service

  alias Conveyor.Artifacts.Resource
  alias Conveyor.Blobs
  alias Google.Bytestream, as: BS

  @chunk 64 * 1024

  @spec read(BS.ReadRequest.t(), GRPC.Server.Stream.t()) :: any()
  def read(%BS.ReadRequest{} = req, stream) do
    ref = parse!(Resource.parse_read(req.resource_name))

    case Blobs.stream(project_id(stream), ref.hash, chunk_size: @chunk) do
      {:ok, chunks} ->
        chunks
        |> slice(req.read_offset, req.read_limit)
        |> Enum.each(&GRPC.Server.send_reply(stream, %BS.ReadResponse{data: &1}))

        :ok

      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "blob #{ref.hash} not found"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  @spec write(Enumerable.t(), GRPC.Server.Stream.t()) :: any()
  def write(requests, stream) do
    sink_enabled!()
    project_id = project_id(stream)
    {:ok, holder} = Agent.start_link(fn -> nil end)

    data =
      Stream.map(requests, fn %BS.WriteRequest{} = req ->
        if req.resource_name != "" and Agent.get(holder, & &1) == nil do
          ref = parse!(Resource.parse_write(req.resource_name))
          Agent.update(holder, fn _ -> ref end)
        end

        req.data
      end)

    result = Blobs.put(project_id, data, source: "cas", ttl_seconds: cas_ttl_seconds())
    ref = Agent.get(holder, & &1)
    Agent.stop(holder)

    response =
      case {result, ref} do
        {_, nil} ->
          raise GRPC.RPCError, status: :invalid_argument, message: "missing resource_name"

        {{:ok, %{digest: digest, size: size}}, %Resource{hash: digest, size: size}} ->
          %BS.WriteResponse{committed_size: size}

        {{:ok, blob}, ref} ->
          # The bytes are stored under their true digest with a TTL; the client's claim
          # was wrong, so tell it and let retention drop the blob.
          raise GRPC.RPCError,
            status: :invalid_argument,
            message:
              "uploaded #{blob.size} bytes hashing to #{blob.digest}, expected #{ref.size} bytes hashing to #{ref.hash}"

        {{:error, %GRPC.RPCError{} = error}, _} ->
          raise error

        {{:error, reason}, _} ->
          raise GRPC.RPCError, status: :internal, message: inspect(reason)
      end

    # Client-streaming RPCs return their single response directly.
    response
  end

  @spec query_write_status(BS.QueryWriteStatusRequest.t(), GRPC.Server.Stream.t()) :: any()
  def query_write_status(%BS.QueryWriteStatusRequest{} = req, stream) do
    sink_enabled!()
    ref = parse!(Resource.parse_write(req.resource_name))

    response =
      case Blobs.get(project_id(stream), ref.hash) do
        %{size: size} -> %BS.QueryWriteStatusResponse{committed_size: size, complete: true}
        nil -> %BS.QueryWriteStatusResponse{committed_size: 0, complete: false}
      end

    response |> GRPC.Stream.unary(materializer: stream) |> GRPC.Stream.run()
  end

  @doc "The project of the authenticated caller (`Conveyor.Grpc.AuthInterceptor`)."
  @spec project_id(GRPC.Server.Stream.t()) :: integer()
  def project_id(%{local: %{ctx: %{project_id: id}}}), do: id

  @doc "Raises UNIMPLEMENTED unless the CAS sink is enabled."
  def sink_enabled! do
    unless Application.get_env(:conveyor, Conveyor.Grpc, []) |> Keyword.get(:cas_sink, false) do
      raise GRPC.RPCError,
        status: :unimplemented,
        message: "the CAS sink is disabled (set CAS_SINK_ENABLED=true)"
    end
  end

  @doc "Blob lifetime for CAS uploads, in seconds."
  def cas_ttl_seconds do
    days = Application.get_env(:conveyor, Conveyor.Grpc, []) |> Keyword.get(:cas_ttl_days, 14)
    days * 24 * 60 * 60
  end

  defp parse!({:ok, ref}), do: ref

  defp parse!({:error, :unsupported_digest}),
    do:
      raise(GRPC.RPCError,
        status: :invalid_argument,
        message: "only sha256 digests are supported"
      )

  defp parse!({:error, :invalid_resource}),
    do: raise(GRPC.RPCError, status: :invalid_argument, message: "malformed resource name")

  # Applies ByteStream read_offset / read_limit to a stream of chunks.
  @doc false
  def slice(chunks, offset, limit) do
    limit = if limit > 0, do: limit, else: :infinity

    Stream.transform(chunks, {offset, limit}, fn
      _chunk, {_skip, 0} ->
        {:halt, {0, 0}}

      chunk, {skip, remaining} when skip >= byte_size(chunk) ->
        {[], {skip - byte_size(chunk), remaining}}

      chunk, {skip, remaining} ->
        chunk = binary_part(chunk, skip, byte_size(chunk) - skip)

        cond do
          remaining == :infinity -> {[chunk], {0, :infinity}}
          byte_size(chunk) >= remaining -> {[binary_part(chunk, 0, remaining)], {0, 0}}
          true -> {[chunk], {0, remaining - byte_size(chunk)}}
        end
    end)
  end
end
