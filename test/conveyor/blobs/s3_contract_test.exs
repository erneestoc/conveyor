defmodule Conveyor.Blobs.S3ContractTest do
  @moduledoc """
  On-demand contract test against a real S3-compatible store (M9 D4). Excluded by default;
  run with the store's details in the environment:

      S3_TEST_BUCKET=conveyor-test S3_TEST_ENDPOINT=http://localhost:9000 S3_TEST_PATH_STYLE=true \\
      AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... mix test --only s3

  Against AWS itself omit the endpoint (and set S3_TEST_REGION). Objects are written under
  the `contract-test` prefix and deleted afterwards.
  """
  use ExUnit.Case, async: false

  alias Conveyor.Blobs
  alias Conveyor.Blobs.S3

  @moduletag :s3

  setup_all do
    bucket =
      System.get_env("S3_TEST_BUCKET") ||
        raise "S3_TEST_BUCKET (and credentials) must be set to run the S3 contract test"

    opts = [
      bucket: bucket,
      region: System.get_env("S3_TEST_REGION", "us-east-1"),
      endpoint: System.get_env("S3_TEST_ENDPOINT"),
      path_style: System.get_env("S3_TEST_PATH_STYLE") in ~w(true 1),
      prefix: "contract-test",
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      session_token: System.get_env("AWS_SESSION_TOKEN")
    ]

    {:ok, opts: opts}
  end

  test "put, head, get (streamed), delete round-trip", %{opts: opts} do
    content = :crypto.strong_rand_bytes(200_000)
    digest = Blobs.digest(content)

    refute S3.exists?(digest, opts)
    assert {:error, :not_found} = S3.stream(digest, opts)

    chunks = for <<c::binary-size(65_536) <- content>>, do: c

    rest =
      binary_part(
        content,
        byte_size(content) - rem(byte_size(content), 65_536),
        rem(byte_size(content), 65_536)
      )

    assert :ok =
             S3.put(
               digest,
               chunks ++ [rest],
               Keyword.put(opts, :content_type, "application/octet-stream")
             )

    assert S3.exists?(digest, opts)
    assert {:ok, stream} = S3.stream(digest, opts)
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == content

    assert :ok = S3.delete(digest, opts)
    refute S3.exists?(digest, opts)
    # Deleting again is idempotent.
    assert :ok = S3.delete(digest, opts)
  end

  test "the object key follows the configured prefix and addressing style", %{opts: opts} do
    digest = String.duplicate("ab", 32)
    url = S3.url(digest, opts)
    assert url =~ "/contract-test/"
    assert url =~ digest
    if opts[:endpoint], do: assert(String.starts_with?(url, opts[:endpoint]))
  end

  test "a project prefix is one more path segment under the bucket prefix", %{opts: opts} do
    content = "per-project #{System.unique_integer()}"
    digest = Blobs.digest(content)
    scoped = Keyword.put(opts, :project_prefix, "contract-project")
    assert S3.url(digest, scoped) =~ "/contract-test/contract-project/#{digest}"

    assert :ok = S3.put(digest, [content], scoped)
    assert S3.exists?(digest, scoped)
    # The same digest without the project prefix is a different object.
    refute S3.exists?(digest, opts)
    assert {:ok, stream} = S3.stream(digest, scoped)
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == content
    assert :ok = S3.delete(digest, scoped)
    refute S3.exists?(digest, scoped)
  end
end
