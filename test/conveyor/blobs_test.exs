defmodule Conveyor.BlobsTest do
  use Conveyor.DataCase, async: true

  alias Conveyor.Blobs

  test "validates digests" do
    assert Blobs.valid_digest?(String.duplicate("0", 64))
    refute Blobs.valid_digest?(String.duplicate("0", 63))
    refute Blobs.valid_digest?(String.duplicate("A", 64))
    refute Blobs.valid_digest?("../../etc/passwd")
    refute Blobs.valid_digest?(nil)
    assert Blobs.get("../x") == nil
    assert {:error, :not_found} = Blobs.stream("../x")
    assert :ok = Blobs.delete("../x")
  end

  test "stores a binary under its digest and reads it back" do
    content = "profile bytes #{System.unique_integer()}"
    digest = Blobs.digest(content)
    refute Blobs.exists?(digest)
    assert [^digest] = Blobs.missing([digest, "junk"]) |> Enum.reject(&(&1 == "junk"))

    assert {:ok, blob} = Blobs.put(content, content_type: "application/gzip", source: "upload")
    assert blob.digest == digest
    assert blob.size == byte_size(content)
    assert blob.storage == "disk"
    assert blob.source == "upload"
    assert blob.expires_at == nil
    assert Blobs.exists?(digest)
    assert Blobs.missing([digest]) == []
    assert {:ok, ^content} = Blobs.read(digest)
    assert Blobs.get(digest).last_used_at != nil

    assert :ok = Blobs.delete(digest)
    refute Blobs.exists?(digest)
    assert {:error, :not_found} = Blobs.read(digest)
  end

  test "refuses content that does not match the declared digest" do
    other = Blobs.digest("something else")
    assert {:error, :digest_mismatch} = Blobs.put("content", digest: other)
    assert {:error, :invalid_digest} = Blobs.put("content", digest: "nope")

    assert {:error, :digest_mismatch} =
             Blobs.put(Stream.map(["con", "tent"], & &1), digest: other)

    refute Blobs.exists?(other)
  end

  test "streams content while hashing it" do
    chunks = for i <- 1..5, do: :crypto.strong_rand_bytes(1000) <> <<i>>
    digest = Blobs.digest(chunks)
    assert {:ok, blob} = Blobs.put(Stream.map(chunks, & &1), digest: digest)
    assert blob.size == 5005
    assert {:ok, data} = Blobs.read(digest)
    assert data == IO.iodata_to_binary(chunks)

    # Streams without a declared digest are buffered.
    chunks2 = ["a", "b"]
    assert {:ok, blob2} = Blobs.put(Stream.map(chunks2, & &1))
    assert blob2.digest == Blobs.digest("ab")
  end

  test "expiry, pinning and pruning" do
    content = "cas upload #{System.unique_integer()}"
    assert {:ok, blob} = Blobs.put(content, source: "cas", ttl_seconds: -1)
    assert DateTime.compare(blob.expires_at, DateTime.utc_now()) == :lt

    pinned = "pinned #{System.unique_integer()}"
    assert {:ok, p} = Blobs.put(pinned, ttl_seconds: -1)
    assert :ok = Blobs.pin(p.digest)
    # Re-uploading a pinned blob keeps it pinned; re-uploading an expiring one refreshes it.
    assert {:ok, p2} = Blobs.put(pinned, ttl_seconds: 3600)
    assert p2.expires_at == nil
    assert {:ok, b2} = Blobs.put(content, source: "cas", ttl_seconds: 3600)
    assert DateTime.compare(b2.expires_at, DateTime.utc_now()) == :gt

    assert {:ok, again} = Blobs.put(content, source: "cas", ttl_seconds: -1)
    assert Blobs.prune_expired() >= 1
    refute Blobs.exists?(again.digest)
    assert Blobs.exists?(p.digest)
  end
end
