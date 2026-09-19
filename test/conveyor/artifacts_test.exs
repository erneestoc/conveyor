defmodule Conveyor.ArtifactsTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  @moduletag :capture_log

  alias Conveyor.{Artifacts, Blobs, FakeCache, Projects, Repo}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Workers.FetchProfile

  setup_all do
    %{cache_port: FakeCache.start()}
  end

  setup %{cache_port: port} do
    project = Projects.ensure_default_project!()
    {:ok, project} = Projects.delete_cache_endpoint(project, "127.0.0.1:#{port}")
    inv = insert_invocation(project)
    %{project: project, inv: inv, authority: "127.0.0.1:#{port}"}
  end

  defp insert_invocation(project, attrs \\ %{}) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %Invocation{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
  end

  test "rejects local files and unsupported references", %{inv: inv} do
    assert {:error, :local_file} = Artifacts.fetch(inv, %{"uri" => "file:///tmp/test.log"})
    assert {:error, :no_uri} = Artifacts.fetch(inv, %{"name" => "test.log"})
    assert {:error, :no_uri} = Artifacts.fetch(inv, nil)
    assert {:error, :unsupported_scheme} = Artifacts.fetch(inv, %{"uri" => "https://x/y"})
  end

  test "stores inline contents", %{inv: inv} do
    assert {:ok, digest} = Artifacts.fetch(inv, %{"contents" => "inline"})
    assert {:ok, "inline"} = Blobs.read(digest)
    assert {:ok, digest2} = Artifacts.fetch(inv, %{"contents" => "AP8="})
    assert {:ok, "AP8="} = Blobs.read(digest2)
  end

  test "serves blobs already in the store without contacting anyone", %{inv: inv} do
    {:ok, blob} = Blobs.put("already here")
    uri = "bytestream://nowhere.invalid/blobs/#{blob.digest}/12"
    assert {:ok, digest} = Artifacts.fetch(inv, %{"uri" => uri})
    assert digest == blob.digest
  end

  test "only fetches from configured endpoints", %{
    inv: inv,
    project: project,
    authority: authority
  } do
    data = "profile #{System.unique_integer()}"
    resource = FakeCache.serve(data)
    uri = "bytestream://#{authority}/#{resource}"

    assert {:error, :endpoint_not_configured} = Artifacts.fetch(inv, %{"uri" => uri})

    {:ok, _} =
      Projects.put_cache_endpoint(project, authority, %{
        "headers" => %{"x-api-key" => "secret"},
        "tls" => false
      })

    assert {:ok, digest} = Artifacts.fetch(inv, %{"uri" => uri, "name" => "command.profile.gz"})
    assert {:ok, ^data} = Blobs.read(digest)
    assert Blobs.get(digest).content_type == "application/gzip"
    assert FakeCache.headers()["x-api-key"] == "secret"

    # Second fetch is served locally.
    assert {:ok, ^digest} = Artifacts.fetch(inv, %{"uri" => uri})
  end

  test "verifies content, reports missing blobs and size limits", %{
    inv: inv,
    project: project,
    authority: authority
  } do
    {:ok, _} =
      Projects.put_cache_endpoint(project, authority, %{"headers" => %{}, "tls" => false})

    wrong = FakeCache.serve("wrong bytes", Blobs.digest("right bytes"))

    assert {:error, :digest_mismatch} =
             Artifacts.fetch(inv, %{"uri" => "bytestream://#{authority}/#{wrong}"})

    refute Blobs.exists?(Blobs.digest("right bytes"))

    missing = "blobs/#{Blobs.digest("missing")}/7"

    assert {:error, {:rpc, :not_found, _}} =
             Artifacts.fetch(inv, %{"uri" => "bytestream://#{authority}/#{missing}"})

    big = "bytestream://#{authority}/blobs/#{Blobs.digest("big")}/#{10 * 1024 * 1024 * 1024}"
    assert {:error, :too_large} = Artifacts.fetch(inv, %{"uri" => big})

    {:ok, _} =
      Projects.put_cache_endpoint(project, "127.0.0.1:1", %{"headers" => %{}, "tls" => false})

    down = "bytestream://127.0.0.1:1/blobs/#{Blobs.digest("down")}/4"
    assert {:error, {:connect, _}} = Artifacts.fetch(inv, %{"uri" => down})
  end

  test "endpoint lookup falls back from host:port to host", %{project: project} do
    {:ok, project} =
      Projects.put_cache_endpoint(project, "cache.internal", %{
        "headers" => %{"a" => "b"},
        "tls" => true
      })

    {:ok, ref} =
      Conveyor.Artifacts.Resource.parse_uri(
        "bytestream://cache.internal:443/blobs/#{Blobs.digest("x")}/1"
      )

    assert %{"tls" => true, "headers" => %{"a" => "b"}} = Artifacts.endpoint_for(project, ref)
    assert {:error, :invalid_host} = Projects.put_cache_endpoint(project, "bad host/../", %{})
    assert Artifacts.content_type("x.xml") == "application/xml"
    assert Artifacts.content_type("x.json") == "application/json"
    assert Artifacts.content_type(nil) == "application/octet-stream"
  end

  test "attaches named artifacts and replaces by name", %{inv: inv} do
    {:ok, b1} = Blobs.put("v1", ttl_seconds: 10)
    {:ok, b2} = Blobs.put("v2")
    a1 = Artifacts.attach(inv, "notes.txt", b1, "upload")
    assert a1.digest == b1.digest
    assert Blobs.get(b1.digest).expires_at == nil
    a2 = Artifacts.attach(inv.id, "notes.txt", b2, "upload")
    assert a2.digest == b2.digest
    assert [%{name: "notes.txt", digest: digest}] = Artifacts.list(inv)
    assert digest == b2.digest
    assert Artifacts.get(inv, "notes.txt").source == "upload"
    assert Artifacts.get(inv, "other") == nil
  end

  describe "profile lifecycle" do
    test "local profiles are marked unavailable at finalization", %{project: project} do
      inv =
        insert_invocation(project, %{
          profile_status: "referenced",
          profile_uri: "file:///tmp/command.profile.gz"
        })

      :ok = Artifacts.on_finalized(inv.id)
      assert Repo.get!(Invocation, inv.id).profile_status == "unavailable"
      refute_enqueued(worker: FetchProfile)
      assert :ok = Artifacts.on_finalized(Ecto.UUID.generate())
    end

    test "profiles already in the store become available immediately", %{project: project} do
      {:ok, blob} = Blobs.put("gzipped profile", source: "cas", ttl_seconds: 100)
      uri = "bytestream://anything/blobs/#{blob.digest}/#{blob.size}"
      inv = insert_invocation(project, %{profile_status: "referenced", profile_uri: uri})
      Phoenix.PubSub.subscribe(Conveyor.PubSub, Conveyor.Ingest.invocation_topic(inv.id))
      :ok = Artifacts.on_finalized(inv.id)
      assert %{profile_status: "available", profile_blob: digest} = Repo.get!(Invocation, inv.id)
      assert digest == blob.digest
      assert Blobs.get(digest).expires_at == nil
      assert [%{name: "command.profile.gz", source: "cas"}] = Artifacts.list(inv)
      assert_receive {:artifacts_changed, _}
      refute_enqueued(worker: FetchProfile)
    end

    test "remote profiles are fetched by a job", %{project: project, authority: authority} do
      data = "remote profile #{System.unique_integer()}"
      resource = FakeCache.serve(data)
      uri = "bytestream://#{authority}/#{resource}"
      inv = insert_invocation(project, %{profile_status: "referenced", profile_uri: uri})

      :ok = Artifacts.on_finalized(inv.id)
      assert_enqueued(worker: FetchProfile, args: %{invocation_id: inv.id})

      # No endpoint configured: permanent.
      assert {:cancel, :endpoint_not_configured} =
               perform_job(FetchProfile, %{invocation_id: inv.id})

      assert Repo.get!(Invocation, inv.id).profile_status == "unavailable"

      {:ok, _} =
        Projects.put_cache_endpoint(project, authority, %{"headers" => %{}, "tls" => false})

      assert :ok = perform_job(FetchProfile, %{invocation_id: inv.id})
      assert %{profile_status: "available", profile_blob: digest} = Repo.get!(Invocation, inv.id)
      assert {:ok, ^data} = Blobs.read(digest)
      assert :ok = perform_job(FetchProfile, %{invocation_id: inv.id})

      # Missing on the cache: permanent. Unreachable cache: retried.
      gone =
        insert_invocation(project, %{
          profile_status: "referenced",
          profile_uri: "bytestream://#{authority}/blobs/#{Blobs.digest("gone")}/4"
        })

      assert {:cancel, {:rpc, :not_found, _}} =
               perform_job(FetchProfile, %{invocation_id: gone.id})

      {:ok, _} =
        Projects.put_cache_endpoint(project, "127.0.0.1:1", %{"headers" => %{}, "tls" => false})

      down =
        insert_invocation(project, %{
          profile_status: "referenced",
          profile_uri: "bytestream://127.0.0.1:1/blobs/#{Blobs.digest("down")}/4"
        })

      assert {:error, {:connect, _}} = perform_job(FetchProfile, %{invocation_id: down.id})
      assert Repo.get!(Invocation, down.id).profile_status == "failed"

      assert {:cancel, :no_invocation} =
               perform_job(FetchProfile, %{invocation_id: Ecto.UUID.generate()})

      assert {:unavailable, :no_uri} = Artifacts.fetch_profile(%Invocation{id: inv.id})
    end
  end
end
