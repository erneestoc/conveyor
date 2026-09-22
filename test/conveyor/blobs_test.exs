defmodule Conveyor.BlobsTest do
  use Conveyor.DataCase, async: true

  alias Conveyor.{Blobs, Projects}
  alias Conveyor.Blobs.Disk

  setup do
    %{project: Projects.ensure_default_project!()}
  end

  test "validates digests", %{project: project} do
    assert Blobs.valid_digest?(String.duplicate("0", 64))
    refute Blobs.valid_digest?(String.duplicate("0", 63))
    refute Blobs.valid_digest?(String.duplicate("A", 64))
    refute Blobs.valid_digest?("../../etc/passwd")
    refute Blobs.valid_digest?(nil)
    assert Blobs.get(project, "../x") == nil
    assert {:error, :not_found} = Blobs.stream(project.id, "../x")
    assert :ok = Blobs.delete(project.id, "../x")
  end

  test "stores a binary under the project's prefix and reads it back", %{project: project} do
    content = "profile bytes #{System.unique_integer()}"
    digest = Blobs.digest(content)
    refute Blobs.exists?(project, digest)
    assert [^digest] = Blobs.missing(project, [digest, "junk"]) |> Enum.reject(&(&1 == "junk"))

    assert {:ok, blob} =
             Blobs.put(project, content, content_type: "application/gzip", source: "upload")

    assert blob.digest == digest
    assert blob.project_id == project.id
    assert blob.prefix == project.slug
    assert blob.size == byte_size(content)
    assert blob.storage == "disk"
    assert blob.source == "upload"
    assert blob.expires_at == nil
    assert Blobs.exists?(project.id, digest)
    assert Blobs.missing(project.id, [digest]) == []
    assert {:ok, ^content} = Blobs.read(project.id, digest)
    assert Blobs.get(project.id, digest).last_used_at != nil

    # The bytes live under <dir>/<prefix>/…, one directory per project.
    {Disk, opts} = Blobs.adapter()
    assert File.regular?(Disk.path(digest, Keyword.put(opts, :project_prefix, project.slug)))

    assert :ok = Blobs.delete(project.id, digest)
    refute Blobs.exists?(project.id, digest)
    assert {:error, :not_found} = Blobs.read(project.id, digest)
  end

  test "projects never share blobs: the same content is stored once per project", %{
    project: project
  } do
    {:ok, other} = Projects.create_project(%{slug: "blobs-other", name: "Other"})
    {:ok, other} = Projects.put_storage(other, %{"blob_prefix" => "custom.prefix"})
    content = "shared #{System.unique_integer()}"
    digest = Blobs.digest(content)

    assert {:ok, a} = Blobs.put(project, content)
    refute Blobs.exists?(other, digest)
    assert Blobs.missing(other, [digest]) == [digest]
    assert {:ok, b} = Blobs.put(other, content)
    assert b.prefix == "custom.prefix" and a.prefix == project.slug

    {Disk, opts} = Blobs.adapter()
    path_a = Disk.path(digest, Keyword.put(opts, :project_prefix, a.prefix))
    path_b = Disk.path(digest, Keyword.put(opts, :project_prefix, b.prefix))
    assert path_a != path_b and File.regular?(path_a) and File.regular?(path_b)

    assert :ok = Blobs.delete(other, digest)
    assert Blobs.exists?(project, digest)
    refute File.regular?(path_b)
  end

  test "refuses content that does not match the declared digest", %{project: project} do
    other = Blobs.digest("something else")
    assert {:error, :digest_mismatch} = Blobs.put(project, "content", digest: other)
    assert {:error, :invalid_digest} = Blobs.put(project, "content", digest: "nope")

    assert {:error, :digest_mismatch} =
             Blobs.put(project, Stream.map(["con", "tent"], & &1), digest: other)

    refute Blobs.exists?(project, other)
  end

  test "streams content while hashing it", %{project: project} do
    chunks = for i <- 1..5, do: :crypto.strong_rand_bytes(1000) <> <<i>>
    digest = Blobs.digest(chunks)
    assert {:ok, blob} = Blobs.put(project, Stream.map(chunks, & &1), digest: digest)
    assert blob.size == 5005
    assert {:ok, data} = Blobs.read(project, digest)
    assert data == IO.iodata_to_binary(chunks)

    # Streams without a declared digest are buffered.
    chunks2 = ["a", "b"]
    assert {:ok, blob2} = Blobs.put(project, Stream.map(chunks2, & &1))
    assert blob2.digest == Blobs.digest("ab")
  end

  test "expiry, pinning and pruning", %{project: project} do
    content = "cas upload #{System.unique_integer()}"
    assert {:ok, blob} = Blobs.put(project, content, source: "cas", ttl_seconds: -1)
    assert DateTime.compare(blob.expires_at, DateTime.utc_now()) == :lt

    pinned = "pinned #{System.unique_integer()}"
    assert {:ok, p} = Blobs.put(project, pinned, ttl_seconds: -1)
    assert :ok = Blobs.pin(project, p.digest)
    # Re-uploading a pinned blob keeps it pinned; re-uploading an expiring one refreshes it.
    assert {:ok, p2} = Blobs.put(project, pinned, ttl_seconds: 3600)
    assert p2.expires_at == nil
    assert {:ok, b2} = Blobs.put(project, content, source: "cas", ttl_seconds: 3600)
    assert DateTime.compare(b2.expires_at, DateTime.utc_now()) == :gt

    assert {:ok, again} = Blobs.put(project, content, source: "cas", ttl_seconds: -1)
    assert Blobs.prune_expired() >= 1
    refute Blobs.exists?(project, again.digest)
    assert Blobs.exists?(project, p.digest)
  end

  test "orphan pruning frees pinned blobs nothing references", %{project: project} do
    import Ecto.Query
    alias Conveyor.Invocations.Invocation

    inv = Repo.insert!(%Invocation{id: Conveyor.Bep.Replay.uuid(), project_id: project.id})
    {:ok, attached} = Blobs.put(project, "attached #{System.unique_integer()}")
    Conveyor.Artifacts.attach(inv, "a.txt", attached, "upload")
    {:ok, profile} = Blobs.put(project, "profile #{System.unique_integer()}")

    Repo.update_all(from(i in Invocation, where: i.id == ^inv.id),
      set: [profile_blob: profile.digest]
    )

    {:ok, orphan} = Blobs.put(project, "orphan #{System.unique_integer()}")
    {:ok, fresh} = Blobs.put(project, "fresh #{System.unique_integer()}")

    # Everything but the fresh blob predates the grace period.
    old = DateTime.add(DateTime.utc_now(), -2, :hour)

    Repo.update_all(
      from(b in Blobs.Blob, where: b.digest != ^fresh.digest and b.project_id == ^project.id),
      set: [inserted_at: old]
    )

    # A reference from another project does not count: the row is per project.
    {:ok, other} = Projects.create_project(%{slug: "blobs-orphan", name: "Orphan"})
    other_inv = Repo.insert!(%Invocation{id: Conveyor.Bep.Replay.uuid(), project_id: other.id})
    {:ok, other_blob} = Blobs.put(other, "orphan #{System.unique_integer()}")
    Conveyor.Artifacts.attach(other_inv, "b.txt", other_blob, "upload")

    Repo.update_all(from(b in Blobs.Blob, where: b.project_id == ^other.id),
      set: [inserted_at: old]
    )

    Repo.delete_all(
      from(a in Conveyor.Invocations.Artifact, where: a.invocation_id == ^other_inv.id)
    )

    assert Blobs.prune_orphans() == 2
    refute Blobs.exists?(project, orphan.digest)
    refute Blobs.exists?(other, other_blob.digest)
    assert Blobs.exists?(project, attached.digest)
    assert Blobs.exists?(project, profile.digest)
    assert Blobs.exists?(project, fresh.digest)

    # Retention deleting the invocation releases its artifact and profile.
    Repo.delete_all(from(i in Invocation, where: i.id == ^inv.id))
    assert Blobs.prune_orphans() == 2
    refute Blobs.exists?(project, attached.digest)
    refute Blobs.exists?(project, profile.digest)
  end
end
