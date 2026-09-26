defmodule Conveyor.RawArchiveS3Test do
  @moduledoc """
  The raw archive against a real S3-compatible store (run with `mix test --only s3` and the
  environment described in `Conveyor.Blobs.S3ContractTest`): the objects are written
  through the spool path, read back through the S3 adapter's one-shot streams and the
  zstd decompression context, byte-identical to the segments, and removed by the prune
  once the build is gone.
  """
  use ConveyorWeb.LiveCase, async: false

  import Ecto.Query

  alias Conveyor.{Blobs, Invocations, RawArchive, Repo}
  alias Conveyor.Ingest.Verify
  alias Conveyor.Invocations.Invocation

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
      prefix: "contract-test-archive",
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      session_token: System.get_env("AWS_SESSION_TOKEN")
    ]

    prev_blobs = Application.get_env(:conveyor, Blobs)
    prev_archive = Application.get_env(:conveyor, RawArchive)
    Application.put_env(:conveyor, Blobs, adapter: :s3, s3: s3)
    Application.put_env(:conveyor, RawArchive, enabled: true, after_hours: 24)

    on_exit(fn ->
      Application.put_env(:conveyor, Blobs, prev_blobs)
      Application.put_env(:conveyor, RawArchive, prev_archive)
    end)

    :ok
  end

  test "archives to S3, streams back identical, and is pruned with the build", %{conn: conn} do
    id = ingest_fixture!("build_only_verbose", context())
    inv = Repo.get!(Invocation, id)
    frames = Invocations.raw_frames(inv)
    log = Invocations.log(inv)
    download = response(get(conn, ~p"/invocation/#{id}/download/log"), 200)

    assert {:ok, :archived} = RawArchive.archive(id, DateTime.add(DateTime.utc_now(), 2, :day))
    inv = Repo.get!(Invocation, id)
    assert Blobs.get(inv.project_id, inv.raw_blob).storage == "s3"

    for table <- ~w(event_segments log_segments),
        do: Repo.query!("DELETE FROM #{table} WHERE invocation_id = $1", [Ecto.UUID.dump!(id)])

    assert Invocations.raw_frames(inv) == frames
    assert Invocations.log(inv) == log
    assert response(get(build_conn(), ~p"/invocation/#{id}/download/log"), 200) == download
    assert :ok = Verify.check(id, inv.last_event_seq - 1)

    Repo.delete_all(from i in Invocation, where: i.id == ^id)
    old = DateTime.add(DateTime.utc_now(), -2, :hour)
    Repo.update_all(from(b in Blobs.Blob, where: b.source == "raw"), set: [inserted_at: old])
    assert Blobs.prune_orphans() >= 2
    refute Blobs.exists?(inv.project_id, inv.raw_blob)
    refute Blobs.exists?(inv.project_id, inv.log_blob)
  end
end
