defmodule Conveyor.Grpc.CasServer do
  @moduledoc """
  The unary half of the built-in CAS sink: `FindMissingBlobs`, `BatchUpdateBlobs` and
  `BatchReadBlobs` over the blob store. Streamed uploads go through
  `Conveyor.Grpc.ByteStreamServer`. Tree, split and splice operations are not offered
  (Bazel does not need them for BEP uploads). Enabled with `CAS_SINK_ENABLED=true`.
  """
  use GRPC.Server, service: Build.Bazel.Remote.Execution.V2.ContentAddressableStorage.Service

  alias Build.Bazel.Remote.Execution.V2, as: RE
  alias Conveyor.Blobs
  alias Conveyor.Grpc.ByteStreamServer

  @max_batch_bytes 4 * 1024 * 1024

  def max_batch_bytes, do: @max_batch_bytes

  def find_missing_blobs(%RE.FindMissingBlobsRequest{} = req, stream) do
    ByteStreamServer.sink_enabled!()
    digest_function!(req.digest_function)

    project_id = ByteStreamServer.project_id(stream)

    missing_hashes =
      req.blob_digests
      |> Enum.map(& &1.hash)
      |> then(&Blobs.missing(project_id, &1))
      |> MapSet.new()

    missing = Enum.filter(req.blob_digests, &(&1.hash in missing_hashes))

    reply(%RE.FindMissingBlobsResponse{missing_blob_digests: missing}, stream)
  end

  def batch_update_blobs(%RE.BatchUpdateBlobsRequest{} = req, stream) do
    ByteStreamServer.sink_enabled!()
    digest_function!(req.digest_function)

    total = Enum.reduce(req.requests, 0, &(byte_size(&1.data) + &2))
    project_id = ByteStreamServer.project_id(stream)

    if total > @max_batch_bytes do
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: "batch of #{total} bytes exceeds #{@max_batch_bytes}"
    end

    responses =
      Enum.map(req.requests, fn %RE.BatchUpdateBlobsRequest.Request{digest: digest, data: data} =
                                  r ->
        status =
          cond do
            r.compressor != :IDENTITY ->
              status(:INVALID_ARGUMENT, "compressed batch uploads are not supported")

            byte_size(data) != digest.size_bytes ->
              status(
                :INVALID_ARGUMENT,
                "data is #{byte_size(data)} bytes, digest says #{digest.size_bytes}"
              )

            true ->
              case Blobs.put(project_id, data,
                     digest: digest.hash,
                     source: "cas",
                     ttl_seconds: ByteStreamServer.cas_ttl_seconds()
                   ) do
                {:ok, _} ->
                  status(:OK, "")

                {:error, :digest_mismatch} ->
                  status(:INVALID_ARGUMENT, "data does not hash to #{digest.hash}")

                {:error, :invalid_digest} ->
                  status(:INVALID_ARGUMENT, "only lowercase hex sha256 digests are accepted")

                {:error, reason} ->
                  status(:INTERNAL, inspect(reason))
              end
          end

        %RE.BatchUpdateBlobsResponse.Response{digest: digest, status: status}
      end)

    reply(%RE.BatchUpdateBlobsResponse{responses: responses}, stream)
  end

  def batch_read_blobs(%RE.BatchReadBlobsRequest{} = req, stream) do
    digest_function!(req.digest_function)
    total = Enum.reduce(req.digests, 0, &(&1.size_bytes + &2))
    project_id = ByteStreamServer.project_id(stream)

    if total > @max_batch_bytes do
      raise GRPC.RPCError,
        status: :invalid_argument,
        message: "requested #{total} bytes exceeds #{@max_batch_bytes}"
    end

    responses =
      Enum.map(req.digests, fn digest ->
        case Blobs.read(project_id, digest.hash) do
          {:ok, data} ->
            %RE.BatchReadBlobsResponse.Response{
              digest: digest,
              data: data,
              status: status(:OK, "")
            }

          {:error, :not_found} ->
            %RE.BatchReadBlobsResponse.Response{
              digest: digest,
              status: status(:NOT_FOUND, "blob not found")
            }

          {:error, reason} ->
            %RE.BatchReadBlobsResponse.Response{
              digest: digest,
              status: status(:INTERNAL, inspect(reason))
            }
        end
      end)

    reply(%RE.BatchReadBlobsResponse{responses: responses}, stream)
  end

  def get_tree(_req, _stream), do: unimplemented("GetTree")
  def split_blob(_req, _stream), do: unimplemented("SplitBlob")
  def get_chunk_mapping(_req, _stream), do: unimplemented("GetChunkMapping")
  def splice_blob(_req, _stream), do: unimplemented("SpliceBlob")
  def register_chunk_mapping(_req, _stream), do: unimplemented("RegisterChunkMapping")

  @doc "Raises INVALID_ARGUMENT for any digest function other than SHA-256 (or unset)."
  def digest_function!(fun) when fun in [:UNKNOWN, :SHA256, 0, 1], do: :ok

  def digest_function!(fun),
    do:
      raise(GRPC.RPCError,
        status: :invalid_argument,
        message: "unsupported digest function #{fun}"
      )

  @doc "A `google.rpc.Status` with the given code name."
  def status(code, message) do
    %Google.Rpc.Status{code: Google.Rpc.Code.value(code), message: message}
  end

  defp reply(response, stream),
    do: response |> GRPC.Stream.unary(materializer: stream) |> GRPC.Stream.run()

  defp unimplemented(name),
    do:
      raise(GRPC.RPCError,
        status: :unimplemented,
        message: "#{name} is not supported by the CAS sink"
      )
end
