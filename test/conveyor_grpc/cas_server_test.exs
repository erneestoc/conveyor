defmodule Conveyor.Grpc.CasServerTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Build.Bazel.Remote.Execution.V2, as: RE
  alias Conveyor.Blobs
  alias Conveyor.Projects

  setup %{project: project, grpc_port: port} do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "cas", scopes: ["ingest"]})
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    %{channel: channel, meta: %{"x-api-key" => plaintext}}
  end

  defp digest(data), do: %RE.Digest{hash: Blobs.digest(data), size_bytes: byte_size(data)}

  test "capabilities advertise a sha256 cache without execution", %{channel: channel, meta: meta} do
    assert {:ok, caps} =
             RE.Capabilities.Stub.get_capabilities(channel, %RE.GetCapabilitiesRequest{},
               metadata: meta
             )

    assert caps.execution_capabilities == nil
    assert caps.cache_capabilities.digest_functions == [:SHA256]
    refute caps.cache_capabilities.action_cache_update_capabilities.update_enabled
    assert caps.cache_capabilities.max_batch_total_size_bytes == 4 * 1024 * 1024
    assert caps.high_api_version.major == 2
  end

  test "find missing, batch update and batch read", %{
    channel: channel,
    meta: meta,
    project: project
  } do
    a = "blob a #{System.unique_integer()}"
    b = "blob b #{System.unique_integer()}"
    {:ok, _} = Blobs.put(project.id, a)

    assert {:ok, %RE.FindMissingBlobsResponse{missing_blob_digests: [missing]}} =
             RE.ContentAddressableStorage.Stub.find_missing_blobs(
               channel,
               %RE.FindMissingBlobsRequest{blob_digests: [digest(a), digest(b)]},
               metadata: meta
             )

    assert missing == digest(b)

    wrong = %RE.Digest{hash: Blobs.digest("something else"), size_bytes: byte_size(b)}
    short = %RE.Digest{hash: Blobs.digest(b), size_bytes: 1}
    bad = %RE.Digest{hash: "XYZ", size_bytes: byte_size(b)}

    assert {:ok, %RE.BatchUpdateBlobsResponse{responses: responses}} =
             RE.ContentAddressableStorage.Stub.batch_update_blobs(
               channel,
               %RE.BatchUpdateBlobsRequest{
                 requests: [
                   %RE.BatchUpdateBlobsRequest.Request{digest: digest(b), data: b},
                   %RE.BatchUpdateBlobsRequest.Request{digest: wrong, data: b},
                   %RE.BatchUpdateBlobsRequest.Request{digest: short, data: b},
                   %RE.BatchUpdateBlobsRequest.Request{digest: bad, data: b},
                   %RE.BatchUpdateBlobsRequest.Request{
                     digest: digest(a),
                     data: a,
                     compressor: :ZSTD
                   }
                 ]
               },
               metadata: meta
             )

    assert [
             %{status: %{code: 0}},
             %{status: %{code: 3}},
             %{status: %{code: 3}},
             %{status: %{code: 3}},
             %{status: %{code: 3}}
           ] = responses

    assert Blobs.get(project.id, Blobs.digest(b)).source == "cas"
    assert Blobs.get(project.id, Blobs.digest(b)).expires_at != nil

    assert {:ok, %RE.BatchReadBlobsResponse{responses: [ra, rb, rmissing]}} =
             RE.ContentAddressableStorage.Stub.batch_read_blobs(
               channel,
               %RE.BatchReadBlobsRequest{digests: [digest(a), digest(b), digest("nope")]},
               metadata: meta
             )

    assert %{data: ^a, status: %{code: 0}} = ra
    assert %{data: ^b, status: %{code: 0}} = rb
    assert %{status: %{code: 5}} = rmissing

    assert {:ok, %RE.FindMissingBlobsResponse{missing_blob_digests: []}} =
             RE.ContentAddressableStorage.Stub.find_missing_blobs(
               channel,
               %RE.FindMissingBlobsRequest{blob_digests: [digest(a), digest(b)]},
               metadata: meta
             )
  end

  test "rejects oversized batches and foreign digest functions", %{channel: channel, meta: meta} do
    huge = %RE.Digest{hash: Blobs.digest("x"), size_bytes: 5 * 1024 * 1024}

    assert {:error, %GRPC.RPCError{status: 3}} =
             RE.ContentAddressableStorage.Stub.batch_read_blobs(
               channel,
               %RE.BatchReadBlobsRequest{digests: [huge]},
               metadata: meta
             )

    big_data = :crypto.strong_rand_bytes(4 * 1024 * 1024 + 1)

    assert {:error, %GRPC.RPCError{status: 3}} =
             RE.ContentAddressableStorage.Stub.batch_update_blobs(
               channel,
               %RE.BatchUpdateBlobsRequest{
                 requests: [
                   %RE.BatchUpdateBlobsRequest.Request{digest: digest(big_data), data: big_data}
                 ]
               },
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 3}} =
             RE.ContentAddressableStorage.Stub.find_missing_blobs(
               channel,
               %RE.FindMissingBlobsRequest{digest_function: :MD5},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ContentAddressableStorage.Stub.get_tree(channel, %RE.GetTreeRequest{},
               metadata: meta
             )
             |> read_stream()

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ContentAddressableStorage.Stub.split_blob(channel, %RE.SplitBlobRequest{},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ContentAddressableStorage.Stub.splice_blob(channel, %RE.SpliceBlobRequest{},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ContentAddressableStorage.Stub.get_chunk_mapping(
               channel,
               %RE.GetChunkMappingRequest{},
               metadata: meta
             )
             |> read_stream()

    stream = RE.ContentAddressableStorage.Stub.register_chunk_mapping(channel, metadata: meta)
    GRPC.Stub.send_request(stream, %RE.RegisterChunkMappingRequest{}, end_stream: true)
    assert {:error, %GRPC.RPCError{status: 12}} = GRPC.Stub.recv(stream)
  end

  test "the action cache always misses and refuses updates", %{channel: channel, meta: meta} do
    assert {:error, %GRPC.RPCError{status: 5}} =
             RE.ActionCache.Stub.get_action_result(
               channel,
               %RE.GetActionResultRequest{action_digest: digest("act")},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 5}} =
             RE.ActionCache.Stub.get_action_result(channel, %RE.GetActionResultRequest{},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 7}} =
             RE.ActionCache.Stub.update_action_result(channel, %RE.UpdateActionResultRequest{},
               metadata: meta
             )
  end

  test "everything but reads is off when the sink is disabled", %{channel: channel, meta: meta} do
    conf = Application.get_env(:conveyor, Conveyor.Grpc)
    Application.put_env(:conveyor, Conveyor.Grpc, Keyword.put(conf, :cas_sink, false))
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Grpc, conf) end)

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.Capabilities.Stub.get_capabilities(channel, %RE.GetCapabilitiesRequest{},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ContentAddressableStorage.Stub.find_missing_blobs(
               channel,
               %RE.FindMissingBlobsRequest{},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ContentAddressableStorage.Stub.batch_update_blobs(
               channel,
               %RE.BatchUpdateBlobsRequest{},
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 12}} =
             RE.ActionCache.Stub.get_action_result(channel, %RE.GetActionResultRequest{},
               metadata: meta
             )

    assert {:ok, %RE.BatchReadBlobsResponse{}} =
             RE.ContentAddressableStorage.Stub.batch_read_blobs(
               channel,
               %RE.BatchReadBlobsRequest{},
               metadata: meta
             )
  end

  defp read_stream({:ok, replies}), do: Enum.find(replies, &match?({:error, _}, &1))
  defp read_stream(other), do: other
end
