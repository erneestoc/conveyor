defmodule Conveyor.Blobs.S3Test do
  use ExUnit.Case, async: true

  alias Conveyor.Blobs.S3

  @creds [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  ]
  @digest String.duplicate("cd", 32)

  test "signature matches the AWS SigV4 GET Object example" do
    # From the AWS "Signature Calculations for the Authorization Header" S3 examples.
    uri = URI.parse("https://examplebucket.s3.amazonaws.com/test.txt")
    now = ~U[2013-05-24 00:00:00Z]

    headers = [
      {"host", "examplebucket.s3.amazonaws.com"},
      {"range", "bytes=0-9"},
      {"x-amz-content-sha256",
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
      {"x-amz-date", "20130524T000000Z"}
    ]

    auth =
      S3.sign(
        :get,
        uri,
        headers,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        now,
        @creds
      )

    assert auth ==
             "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " <>
               "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " <>
               "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  end

  test "signs query strings and encodes path segments" do
    uri = URI.parse("https://b.s3.us-east-1.amazonaws.com/a%20b/c?list-type=2&prefix=blobs/")

    auth =
      S3.sign(
        :get,
        uri,
        [{"host", "b.s3.us-east-1.amazonaws.com"}],
        "UNSIGNED-PAYLOAD",
        ~U[2026-01-01 00:00:00Z],
        @creds
      )

    assert auth =~ "Credential=AKIAIOSFODNN7EXAMPLE/20260101/us-east-1/s3/aws4_request"
  end

  test "builds object URLs for every addressing style" do
    assert S3.url("d", bucket: "b") == "https://b.s3.us-east-1.amazonaws.com/blobs/d"

    assert S3.url("d", bucket: "b", region: "eu-west-1", path_style: true, prefix: "p") ==
             "https://s3.eu-west-1.amazonaws.com/b/p/d"

    assert S3.url("d", bucket: "b", endpoint: "http://minio:9000/", path_style: true) ==
             "http://minio:9000/b/blobs/d"

    assert S3.url("d", bucket: "b", endpoint: "https://r2.example.com") ==
             "https://b.r2.example.com/blobs/d"

    assert S3.url("d", bucket: "b", project_prefix: "mobile") ==
             "https://b.s3.us-east-1.amazonaws.com/blobs/mobile/d"
  end

  describe "against an S3-compatible server" do
    setup do
      {port, store} = Conveyor.FakeS3.start(@creds)

      opts =
        @creds ++
          [
            bucket: "conveyor",
            endpoint: "http://127.0.0.1:#{port}",
            path_style: true,
            session_token: "tok"
          ]

      {:ok, opts: opts, store: store}
    end

    test "put, stream, exists?, delete round trip", %{opts: opts, store: store} do
      refute S3.exists?(@digest, opts)
      assert {:error, :not_found} = S3.stream(@digest, opts)
      assert :ok = S3.put(@digest, ["hello ", "s3"], opts)
      assert Agent.get(store, & &1) == %{"/conveyor/blobs/#{@digest}" => "hello s3"}
      assert S3.exists?(@digest, opts)
      assert {:ok, stream} = S3.stream(@digest, Keyword.put(opts, :chunk_size, 3))
      assert Enum.to_list(stream) == ["hel", "lo ", "s3"]
      assert [] = Path.wildcard(Path.join(System.tmp_dir!(), "conveyor-s3-#{@digest}-*"))
      assert :ok = S3.delete(@digest, opts)
      refute S3.exists?(@digest, opts)
    end

    test "a bad secret is rejected by the server and surfaced as an error", %{opts: opts} do
      bad = Keyword.put(opts, :secret_access_key, "nope")
      assert {:error, {:http, 403, _}} = S3.put(@digest, ["x"], bad)
      assert {:error, {:http, 403, _}} = S3.stream(@digest, bad)
      assert {:error, {:http, 403, _}} = S3.delete(@digest, bad)
      refute S3.exists?(@digest, bad)
    end

    test "delete_objects removes keys in bulk and names the ones the store refused", %{
      opts: opts,
      store: store
    } do
      keys = for i <- 1..3, do: "rawlog/n/0/k#{i}"
      Enum.each(keys, &(:ok = S3.put_object(&1, "bytes", opts)))
      :ok = S3.put_object("rawlog/n/0/refuse&it", "bytes", opts)
      assert map_size(Agent.get(store, & &1)) == 4

      # Absent keys count as deleted; the refused one comes back with the store's reason.
      assert {deleted, [{"rawlog/n/0/refuse&it", {:s3, "AccessDenied", "Access & Denied"}}]} =
               S3.delete_objects(keys ++ ["rawlog/n/0/absent", "rawlog/n/0/refuse&it"], opts)

      assert Enum.sort(deleted) == Enum.sort(keys ++ ["rawlog/n/0/absent"])
      assert Map.keys(Agent.get(store, & &1)) == ["/conveyor/blobs/rawlog/n/0/refuse&it"]

      # More than one request's worth of keys.
      many = for i <- 1..1_001, do: "rawlog/n/1/#{i}"
      assert {gone, []} = S3.delete_objects(many, opts)
      assert length(gone) == 1_001

      # A request that fails as a whole fails every key in it.
      bad = Keyword.put(opts, :secret_access_key, "nope")
      assert {[], [{"a", {:http, 403, _}}, {"b", _}]} = S3.delete_objects(["a", "b"], bad)
      down = Keyword.put(opts, :endpoint, "http://127.0.0.1:1")
      assert {[], [{"a", _}]} = S3.delete_objects(["a"], down)
    end

    test "get_range reads a byte range and reports short reads and missing objects", %{
      opts: opts
    } do
      :ok = S3.put_object("rawlog/n/0/ranged", "0123456789", opts)
      assert {:ok, "345"} = S3.get_range("rawlog/n/0/ranged", 3, 3, opts)
      assert {:error, :short_read} = S3.get_range("rawlog/n/0/ranged", 8, 5, opts)
      assert {:error, :short_read} = S3.get_range("rawlog/n/0/ranged", 20, 1, opts)
      assert {:error, :not_found} = S3.get_range("rawlog/n/0/none", 0, 1, opts)
      bad = Keyword.put(opts, :secret_access_key, "nope")
      assert {:error, {:http, 403, _}} = S3.get_range("rawlog/n/0/ranged", 0, 1, bad)
      assert {:error, {:http, 403, _}} = S3.put_object("rawlog/n/0/ranged", "x", bad)
      down = Keyword.put(opts, :endpoint, "http://127.0.0.1:1")
      assert {:error, _} = S3.get_range("rawlog/n/0/ranged", 0, 1, down)
      assert {:error, _} = S3.put_object("rawlog/n/0/ranged", "x", down)
    end

    test "connection failures are returned, not raised", %{opts: opts} do
      down = Keyword.put(opts, :endpoint, "http://127.0.0.1:1")
      assert {:error, _} = S3.put(@digest, ["x"], down)
      assert {:error, _} = S3.stream(@digest, down)
      assert {:error, _} = S3.delete(@digest, down)
    end
  end
end
