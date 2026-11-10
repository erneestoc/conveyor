defmodule Conveyor.RawLogS3Test do
  @moduledoc """
  The raw log's S3 path (PLAN §25 step 2 item 6) against a real S3-compatible store, run
  with `mix test --only s3` and the environment described in `Conveyor.Blobs.S3ContractTest`
  (the local MinIO: bucket `conveyor-test`, endpoint `http://localhost:9000`, path style,
  the credentials from the `chumti-minio` container's environment). Covers
  `Conveyor.Blobs.S3.put_object/3`, `get_range/4` and `delete/2` for a raw-log key, and
  `Conveyor.RawLog` over the S3 adapter: put, coalesced ranged reads and the sweep.
  """
  use Conveyor.DataCase, async: false

  alias Conveyor.{Blobs, RawLog}
  alias Conveyor.Blobs.S3

  @moduletag :s3

  setup do
    bucket =
      System.get_env("S3_TEST_BUCKET") ||
        raise "S3_TEST_BUCKET (and credentials) must be set to run the S3 tests"

    s3 = [
      bucket: bucket,
      region: System.get_env("S3_TEST_REGION", "us-east-1"),
      endpoint: System.get_env("S3_TEST_ENDPOINT"),
      path_style: System.get_env("S3_TEST_PATH_STYLE") in ~w(true 1),
      prefix: "contract-test-rawlog",
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      session_token: System.get_env("AWS_SESSION_TOKEN")
    ]

    prev = Application.get_env(:conveyor, Blobs)
    Application.put_env(:conveyor, Blobs, adapter: :s3, s3: s3)
    on_exit(fn -> Application.put_env(:conveyor, Blobs, prev) end)
    {:ok, opts: Keyword.put(s3, :project_prefix, nil)}
  end

  test "put_object, get_range (full, partial, past the end, missing) and delete", %{opts: opts} do
    key = RawLog.new_key(7)
    body = :crypto.strong_rand_bytes(300_000)

    assert {:error, :not_found} = S3.get_range(key, 0, 10, opts)
    assert :ok = S3.put_object(key, body, opts)

    assert {:ok, ^body} = S3.get_range(key, 0, byte_size(body), opts)
    assert {:ok, part} = S3.get_range(key, 100_000, 50_000, opts)
    assert part == binary_part(body, 100_000, 50_000)
    assert {:ok, <<_::binary-size(1)>>} = S3.get_range(key, byte_size(body) - 1, 1, opts)

    # A range that runs past the end is a short read, never silently truncated.
    assert {:error, {:short_read, 1000}} = S3.get_range(key, byte_size(body) - 1000, 5000, opts)

    assert :ok = S3.delete(key, opts)
    assert {:error, :not_found} = S3.get_range(key, 0, 10, opts)
    assert :ok = S3.delete(key, opts)
  end

  test "RawLog over S3: put, coalesced ranged reads, sweep" do
    key = RawLog.new_key(3)
    parts = Enum.map(1..5, &String.duplicate(<<&1>>, 10_000))
    assert :ok = RawLog.put(key, parts)

    rows =
      Enum.with_index(parts, fn part, i ->
        %{
          payload: nil,
          object_key: key,
          object_offset: i * 10_000,
          object_length: byte_size(part)
        }
      end)

    counter = :counters.new(1, [])
    handler = "s3-ranges-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:conveyor, :raw_log, :get_range],
      fn _, %{count: c}, _, _ -> :counters.add(counter, 1, c) end,
      nil
    )

    filled = RawLog.fetch_rows!(rows, :payload)
    :telemetry.detach(handler)
    assert Enum.map(filled, & &1.payload) == parts
    assert :counters.get(counter, 1) == 1

    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)).deleted >= 1
    assert_raise RuntimeError, ~r/not_found/, fn -> RawLog.fetch_rows!(rows, :payload) end
  end

  test "the sweep deletes thousands of objects in bulk, faster than a node writes them", %{
    opts: opts
  } do
    keys = for _ <- 1..3_000, do: RawLog.new_key("bulk")

    keys
    |> Task.async_stream(&(:ok = S3.put_object(&1, "bytes", opts)),
      max_concurrency: 16,
      timeout: 60_000
    )
    |> Stream.run()

    Repo.insert_all("raw_log_objects", Enum.map(keys, &%{key: &1}))
    # One more row whose object was never written: absent counts as deleted.
    Repo.insert_all("raw_log_objects", [%{key: "rawlog/bulk/never-written"}])

    cutoff = DateTime.add(DateTime.utc_now(), 1, :second)
    {micros, result} = :timer.tc(fn -> RawLog.sweep(cutoff) end)
    assert %{deleted: deleted, failed: 0, remaining?: false} = result
    assert deleted >= 3_001
    assert Repo.aggregate(from(o in "raw_log_objects"), :count) == 0
    assert {:error, :not_found} = S3.get_range(hd(keys), 0, 1, opts)
    assert {:error, :not_found} = S3.get_range(List.last(keys), 0, 1, opts)

    rate = deleted / (micros / 1_000_000)

    IO.puts(
      "\nraw-log sweep over S3: #{deleted} objects in #{div(micros, 1000)} ms (#{round(rate)}/s)"
    )

    # A node's bound is 8 PUTs a second (one per shard per hold); 153/s was the worst seen.
    assert rate > 500
  end
end
