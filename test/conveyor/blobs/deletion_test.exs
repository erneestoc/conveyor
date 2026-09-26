defmodule Conveyor.Blobs.DeletionTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.{Blobs, Projects}
  alias Conveyor.Invocations.Invocation

  setup do
    prev = Application.get_env(:conveyor, Blobs)
    dir = Path.join(System.tmp_dir!(), "conveyor-flaky-#{System.unique_integer([:positive])}")
    Application.put_env(:conveyor, Blobs, adapter: Blobs.Flaky, opts: [dir: dir])

    on_exit(fn ->
      Application.put_env(:conveyor, Blobs, prev)
      Application.delete_env(:conveyor, :flaky_blob_deletes)
      File.rm_rf(dir)
    end)

    %{project: Projects.ensure_default_project!()}
  end

  # docs/spec/Blobs.tla (ObjectUnderLock): the object goes while the row lock is held,
  # then the row; a delete that cannot remove the object keeps the row.
  test "a failed object delete keeps the row", %{project: project} do
    {:ok, blob} = Blobs.put(project, "keep me #{System.unique_integer()}")
    Application.put_env(:conveyor, :flaky_blob_deletes, true)

    assert {:error, :store_unavailable} = Blobs.delete(project, blob.digest)
    assert Blobs.get(project, blob.digest)
    assert Blobs.exists?(project, blob.digest)

    Application.put_env(:conveyor, :flaky_blob_deletes, false)
    assert :ok = Blobs.delete(project, blob.digest)
    refute Blobs.get(project, blob.digest)
  end

  test "discard deletes only what nothing references", %{project: project} do
    {:ok, raw} = Blobs.put(project, "raw #{System.unique_integer()}")
    {:ok, log} = Blobs.put(project, "log #{System.unique_integer()}")
    {:ok, loose} = Blobs.put(project, "loose #{System.unique_integer()}")

    Repo.insert!(%Invocation{
      id: Conveyor.Bep.Replay.uuid(),
      project_id: project.id,
      raw_status: "archived",
      raw_blob: raw.digest,
      log_blob: log.digest
    })

    assert :skipped = Blobs.discard(project, raw.digest)
    assert :skipped = Blobs.discard(project, log.digest)
    assert :ok = Blobs.discard(project, loose.digest)
    assert :gone = Blobs.discard(project, loose.digest)
    assert Blobs.exists?(project, raw.digest) and Blobs.exists?(project, log.digest)
    refute Blobs.exists?(project, loose.digest)

    # A blob with an expiry is not the writer's to discard (the TTL decides).
    {:ok, ttl} = Blobs.put(project, "ttl #{System.unique_integer()}", ttl_seconds: 60)
    assert :skipped = Blobs.discard(project, ttl.digest)
  end
end
