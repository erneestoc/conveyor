defmodule Conveyor.Workers.ProfileSummaryTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.{Artifacts, Blobs, Invocations, Projects, Repo}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Workers.{BlobMaintenance, ProfileSummary}

  @fixture Path.join([
             File.cwd!(),
             "test/fixtures/blobs",
             "c9fb9e145e0fbb8955f0a0f93e7cfa750e3ab9e6e15387e5caacf811cfa7ec86"
           ])

  setup do
    project = Projects.ensure_default_project!()
    now = DateTime.utc_now()

    inv =
      Repo.insert!(%Invocation{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        inserted_at: now,
        updated_at: now
      })

    %{inv: inv}
  end

  test "summarizes an available profile into the metrics row", %{inv: inv} do
    {:ok, blob} =
      Blobs.put(inv.project_id, File.read!(@fixture), content_type: "application/gzip")

    Phoenix.PubSub.subscribe(Conveyor.PubSub, Conveyor.Ingest.invocation_topic(inv.id))
    :ok = Artifacts.profile_available(inv, blob)
    assert_enqueued(worker: ProfileSummary, args: %{invocation_id: inv.id})

    assert :ok = perform_job(ProfileSummary, %{invocation_id: inv.id})
    assert %{"event_count" => 1297} = Invocations.metrics(inv).profile_summary
    assert_receive {:artifacts_changed, _}

    # Re-running replaces the summary and keeps other metrics columns.
    assert :ok = perform_job(ProfileSummary, %{invocation_id: inv.id})
  end

  test "cancels when there is nothing to summarize", %{inv: inv} do
    assert {:cancel, :no_profile} = perform_job(ProfileSummary, %{invocation_id: inv.id})

    assert {:cancel, :no_invocation} =
             perform_job(ProfileSummary, %{invocation_id: Ecto.UUID.generate()})

    {:ok, blob} = Blobs.put(inv.project_id, "{\"traceEvents\": [{\"bad\": }]}")
    :ok = Artifacts.profile_available(inv, blob)

    assert {:cancel, {:malformed_profile, _}} =
             perform_job(ProfileSummary, %{invocation_id: inv.id})

    :ok = Blobs.delete(inv.project_id, blob.digest)
    assert {:cancel, :blob_missing} = perform_job(ProfileSummary, %{invocation_id: inv.id})
  end

  test "blob maintenance prunes expired uploads" do
    project = Projects.ensure_default_project!()

    {:ok, blob} =
      Blobs.put(project.id, "expired #{System.unique_integer()}", source: "cas", ttl_seconds: -10)

    assert {:ok, %{pruned: n}} = BlobMaintenance.perform(%Oban.Job{})
    assert n >= 1
    refute Blobs.exists?(project.id, blob.digest)
  end
end
