defmodule Conveyor.Artifacts.ResourceTest do
  use ExUnit.Case, async: true

  alias Conveyor.Artifacts.Resource

  @hash String.duplicate("ab", 32)

  test "parses read resource names with and without instance names" do
    assert {:ok, %Resource{instance: "", hash: @hash, size: 12}} =
             Resource.parse_read("blobs/#{@hash}/12")

    assert {:ok, %Resource{instance: "main/x", hash: @hash, size: 0}} =
             Resource.parse_read("main/x/blobs/sha256/#{@hash}/0")

    assert {:error, :unsupported_digest} = Resource.parse_read("blobs/blake3/#{@hash}/1")
    assert {:error, :invalid_resource} = Resource.parse_read("blobs/#{String.upcase(@hash)}/1")
    assert {:error, :invalid_resource} = Resource.parse_read("blobs/../../etc/passwd")
    assert {:error, :invalid_resource} = Resource.parse_read("uploads/u/blobs/#{@hash}/1")
  end

  test "parses write resource names" do
    assert {:ok, %Resource{instance: "", hash: @hash, size: 5}} =
             Resource.parse_write("uploads/u-1/blobs/#{@hash}/5")

    assert {:ok, %Resource{instance: "inst", hash: @hash, size: 5}} =
             Resource.parse_write("inst/uploads/u-1/blobs/#{@hash}/5/some/meta")

    assert {:error, :invalid_resource} = Resource.parse_write("blobs/#{@hash}/5")

    assert {:error, :unsupported_digest} =
             Resource.parse_write("uploads/u/blobs/sha512/#{@hash}/5")
  end

  test "parses bytestream URIs" do
    assert {:ok, ref} =
             Resource.parse_uri("bytestream://cache.example.com:8980/inst/blobs/#{@hash}/7")

    assert %Resource{host: "cache.example.com", port: 8980, instance: "inst", size: 7} = ref
    assert Resource.authority(ref) == "cache.example.com:8980"

    assert {:ok, ref} = Resource.parse_uri("bytestream://cache/blobs/#{@hash}/7")
    assert %Resource{host: "cache", port: nil} = ref
    assert Resource.authority(ref) == "cache"

    assert {:ok, %Resource{host: "h:x", port: nil}} =
             Resource.parse_uri("bytestream://h:x/blobs/#{@hash}/7")

    assert {:error, :invalid_resource} = Resource.parse_uri("bytestream:///blobs/#{@hash}/7")
    assert {:error, :invalid_resource} = Resource.parse_uri("bytestream://host")
    assert {:error, :local_file} = Resource.parse_uri("file:///tmp/x")
    assert {:error, :unsupported_scheme} = Resource.parse_uri("https://x/y")
  end
end
