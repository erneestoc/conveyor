defmodule Conveyor.RawStoreS3Test do
  @moduledoc """
  The contract of `Conveyor.RawStore` (`Conveyor.RawStoreContract`) against a real
  S3-compatible store: run with `mix test --only s3` and the environment described in
  `Conveyor.Blobs.S3ContractTest` (the local MinIO: bucket `conveyor-test`, endpoint
  `http://localhost:9000`, path style, the credentials from the `chumti-minio` container's
  environment). Raw-log objects, ranged reads, the archived blobs and the bulk sweep all
  go through `Conveyor.Blobs.S3`.
  """
  use ConveyorWeb.LiveCase, async: false

  import Conveyor.IngestCase, only: [raw_log_mode!: 2]
  import Conveyor.RawStoreContract
  import Ecto.Query

  alias Conveyor.{Blobs, RawStore, Repo}
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
      prefix: "contract-test-rawstore",
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      session_token: System.get_env("AWS_SESSION_TOKEN")
    ]

    previous = Application.get_env(:conveyor, Blobs)
    Application.put_env(:conveyor, Blobs, adapter: :s3, s3: s3)
    on_exit(fn -> Application.put_env(:conveyor, Blobs, previous) end)
    %{project: Conveyor.Projects.ensure_default_project!(), ctx: context()}
  end

  for {name, modes} <- [
        blob: [:blob],
        postgres: [:postgres],
        "mode changed mid-build": [:postgres, :blob]
      ] do
    test "#{name}: payload or range, archived, partition dropped, objects swept", %{
      project: project
    } do
      assert :ok = lifecycle!(project, unquote(modes))
    end
  end

  test "blob, no compaction: the partition goes after raw retention, the objects after the partition",
       %{project: project} do
    assert :ok = hot_expiry!(project, [:blob])
  end

  test "through the pipeline in blob mode: stored as sent, archived to S3, downloads identical",
       %{conn: conn, ctx: ctx} do
    compaction!(true)
    raw_log_mode!(:blob, flush_ms: 20)
    id = ingest_fixture!("build_only_verbose", ctx)
    before = reads(Repo.get!(Invocation, id))
    assert before.bep == File.read!("test/fixtures/bep/build_only_verbose.bep")
    download = response(get(conn, ~p"/invocation/#{id}/download/log"), 200)

    assert {:ok, :archived} = RawStore.compact(id, DateTime.add(DateTime.utc_now(), 2, :day))
    inv = Repo.get!(Invocation, id)
    assert Blobs.get(inv.project_id, inv.raw_blob).storage == "s3"
    RawStore.expire_partitions(Date.add(Date.utc_today(), raw_days() + 1))
    clock = DateTime.add(DateTime.utc_now(), raw_days() + 2, :day)
    assert %{deleted: deleted, failed: 0} = RawStore.expire_objects(clock)
    assert deleted >= 1

    assert reads(inv) == before
    assert response(get(build_conn(), ~p"/invocation/#{id}/download/log"), 200) == download
    assert :ok = Conveyor.Ingest.Verify.check(id, inv.last_event_seq - 1)

    Repo.delete_all(from i in Invocation, where: i.id == ^id)
    assert Blobs.prune_orphans(DateTime.add(DateTime.utc_now(), 2, :hour)) >= 2
    refute Blobs.exists?(inv.project_id, inv.raw_blob)
  end

  test "the sweep deletes thousands of objects in bulk, faster than a node writes them", %{
    project: project
  } do
    compaction!(false)
    a = build!(project)
    Enum.reduce(1..2_500, a, fn i, a -> hd(append!([{a, ["#{i}"], ""}], :blob, "bulk")) end)
    RawStore.expire_partitions(Date.add(Date.utc_today(), raw_days() + 1))
    clock = DateTime.add(DateTime.utc_now(), raw_days() + 2, :day)
    assert %{objects: 2_500} = RawStore.expiry_backlog(clock)

    {micros, result} = :timer.tc(fn -> RawStore.expire_objects(clock) end)
    assert %{deleted: 2_500, failed: 0, remaining?: false} = result
    assert %{objects: 0} = RawStore.expiry_backlog(clock)
    rate = 2_500 / (micros / 1_000_000)
    IO.puts("\nraw-log sweep over S3: 2500 objects in #{div(micros, 1000)} ms (#{round(rate)}/s)")
    # A node's bound is one object per shard per second; 153/s was the worst measured.
    assert rate > 500
  end
end
