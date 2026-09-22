defmodule Conveyor.Grpc.ByteStreamServerTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Blobs
  alias Conveyor.Grpc.ByteStreamServer
  alias Conveyor.Projects
  alias Google.Bytestream, as: BS
  alias Google.Bytestream.ByteStream.Stub

  setup %{project: project, grpc_port: port} do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "cas", scopes: ["upload"]})
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    %{channel: channel, meta: %{"x-api-key" => plaintext}}
  end

  defp upload(channel, meta, resource, chunks) do
    stream = Stub.write(channel, metadata: meta)
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, i} ->
      req = %BS.WriteRequest{
        resource_name: if(i == 0, do: resource, else: ""),
        data: chunk,
        finish_write: i == last
      }

      GRPC.Stub.send_request(stream, req, end_stream: i == last)
    end)

    GRPC.Stub.recv(stream)
  end

  defp read_all(channel, meta, resource, opts \\ []) do
    req = %BS.ReadRequest{
      resource_name: resource,
      read_offset: opts[:offset] || 0,
      read_limit: opts[:limit] || 0
    }

    with {:ok, replies} <- Stub.read(channel, req, metadata: meta) do
      Enum.reduce_while(replies, {:ok, ""}, fn
        {:ok, %BS.ReadResponse{data: d}}, {:ok, acc} -> {:cont, {:ok, acc <> d}}
        {:error, e}, _ -> {:halt, {:error, e}}
      end)
    end
  end

  test "write, query and read a blob", %{channel: channel, meta: meta, project: project} do
    data = :crypto.strong_rand_bytes(200_000)
    hash = Blobs.digest(data)
    resource = "uploads/#{Ecto.UUID.generate()}/blobs/#{hash}/#{byte_size(data)}"

    assert {:ok, %BS.QueryWriteStatusResponse{complete: false, committed_size: 0}} =
             Stub.query_write_status(
               channel,
               %BS.QueryWriteStatusRequest{resource_name: resource},
               metadata: meta
             )

    chunks = for <<c::binary-size(65_536) <- data>>, do: c
    chunks = chunks ++ [binary_part(data, 196_608, byte_size(data) - 196_608)]

    assert {:ok, %BS.WriteResponse{committed_size: 200_000}} =
             upload(channel, meta, resource, chunks)

    blob = Blobs.get(project.id, hash)
    assert blob.source == "cas"
    assert blob.expires_at != nil

    assert {:ok, %BS.QueryWriteStatusResponse{complete: true, committed_size: 200_000}} =
             Stub.query_write_status(
               channel,
               %BS.QueryWriteStatusRequest{resource_name: resource},
               metadata: meta
             )

    read = "blobs/#{hash}/#{byte_size(data)}"
    assert {:ok, ^data} = read_all(channel, meta, read)
    assert {:ok, part} = read_all(channel, meta, read, offset: 100, limit: 50)
    assert part == binary_part(data, 100, 50)
    assert {:ok, tail} = read_all(channel, meta, read, offset: 199_990)
    assert tail == binary_part(data, 199_990, 10)
  end

  test "rejects bad uploads and unknown reads", %{channel: channel, meta: meta} do
    hash = Blobs.digest("expected")
    resource = "uploads/u/blobs/#{hash}/8"

    assert {:error, %GRPC.RPCError{status: 3, message: msg}} =
             upload(channel, meta, resource, ["not what", " was said"])

    assert msg =~ "expected 8 bytes"

    assert {:error, %GRPC.RPCError{status: 3}} = upload(channel, meta, "garbage", ["x"])

    assert {:error, %GRPC.RPCError{status: 3}} =
             upload(channel, meta, "uploads/u/blobs/md5/#{hash}/8", ["x"])

    assert {:error, %GRPC.RPCError{status: 3, message: "missing resource_name"}} =
             upload(channel, meta, "", ["x"])

    assert {:error, %GRPC.RPCError{status: 5}} =
             read_all(channel, meta, "blobs/#{Blobs.digest("nope")}/4")

    assert {:error, %GRPC.RPCError{status: 3}} = read_all(channel, meta, "blobs/xyz/4")
    assert {:error, %GRPC.RPCError{status: 3}} = read_all(channel, meta, "blobs/sha1/#{hash}/4")

    assert {:error, %GRPC.RPCError{status: 3}} =
             Stub.query_write_status(channel, %BS.QueryWriteStatusRequest{resource_name: "nope"},
               metadata: meta
             )
  end

  @tag :capture_log
  test "uploads require the sink to be enabled; reads always work", %{
    project: project,
    channel: channel,
    meta: meta
  } do
    {:ok, blob} = Blobs.put(project.id, "readable")
    conf = Application.get_env(:conveyor, Conveyor.Grpc)
    Application.put_env(:conveyor, Conveyor.Grpc, Keyword.put(conf, :cas_sink, false))
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Grpc, conf) end)

    assert {:error, %GRPC.RPCError{status: 12}} =
             upload(channel, meta, "uploads/u/blobs/#{blob.digest}/8", ["readable"])

    assert {:error, %GRPC.RPCError{status: 12}} =
             Stub.query_write_status(
               channel,
               %BS.QueryWriteStatusRequest{resource_name: "uploads/u/blobs/#{blob.digest}/8"},
               metadata: meta
             )

    assert {:ok, "readable"} = read_all(channel, meta, "blobs/#{blob.digest}/8")
    assert ByteStreamServer.cas_ttl_seconds() == 86_400
  end

  test "upload-scoped keys cannot publish build events", %{channel: channel, meta: meta} do
    req = %Google.Devtools.Build.V1.PublishLifecycleEventRequest{}

    assert {:error, %GRPC.RPCError{status: 7}} =
             Google.Devtools.Build.V1.PublishBuildEvent.Stub.publish_lifecycle_event(channel, req,
               metadata: meta
             )

    assert {:error, %GRPC.RPCError{status: 16}} =
             read_all(channel, %{}, "blobs/#{Blobs.digest("x")}/1")
  end

  test "slice applies offsets and limits across chunk boundaries" do
    chunks = ["abc", "def", "ghi"]
    assert ByteStreamServer.slice(chunks, 0, 0) |> Enum.join() == "abcdefghi"
    assert ByteStreamServer.slice(chunks, 4, 0) |> Enum.join() == "efghi"
    assert ByteStreamServer.slice(chunks, 1, 4) |> Enum.join() == "bcde"
    assert ByteStreamServer.slice(chunks, 2, 1) |> Enum.join() == "c"
    assert ByteStreamServer.slice(chunks, 9, 0) |> Enum.join() == ""
  end
end
