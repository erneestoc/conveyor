defmodule Conveyor.Projects.MoveTest do
  use ConveyorWeb.LiveCase, async: false

  import Ecto.Query

  alias Conveyor.{Artifacts, Blobs, Invocations, Projects, RawArchive, Repo}
  alias Conveyor.Invocations.{Invocation, TagKey}
  alias Conveyor.Metrics.{Dashboard, Scope}
  alias Conveyor.Projects.Move

  setup do
    prev = Application.get_env(:conveyor, RawArchive)
    Application.put_env(:conveyor, RawArchive, enabled: true, after_hours: 24)
    on_exit(fn -> Application.put_env(:conveyor, RawArchive, prev) end)
    ctx = context()
    %{ctx: ctx, from: Projects.get_project!(ctx.project_id)}
  end

  test "moves matching builds with their blobs, rollups and facets", %{ctx: ctx, from: from} do
    kept = ingest_fixture!("clean_build_and_test", ctx)
    moved = ingest_fixture!("build_failure", ctx)
    inv = Repo.get!(Invocation, moved)

    # A profile, an artifact and archived raw data: three kinds of per-project blobs.
    {:ok, profile} =
      Blobs.put(from, :zlib.gzip("{\"traceEvents\":[]}"), content_type: "application/gzip")

    :ok = Artifacts.profile_available(inv, profile)
    {:ok, notes} = Blobs.put(from, "notes #{System.unique_integer()}")
    {:ok, _} = Artifacts.attach(moved, "notes.txt", notes, "upload")
    assert {:ok, :archived} = RawArchive.archive(moved, DateTime.add(DateTime.utc_now(), 2, :day))
    inv = Repo.get!(Invocation, moved)
    frames = Invocations.raw_frames(inv)
    log = Invocations.log(inv)

    assert {:ok, %{builds: 1, blobs: 4}} =
             Conveyor.Release.move_builds(from.slug, "team-b", "status:failed", "Team B")

    to = Projects.get_project_by_slug("team-b")
    assert to.name == "Team B"
    inv = Repo.get!(Invocation, moved)
    assert inv.project_id == to.id
    assert Repo.get!(Invocation, kept).project_id == from.id

    for digest <- [profile.digest, notes.digest, inv.raw_blob, inv.log_blob],
        do: assert(Blobs.exists?(to, digest), "#{digest} not in the target")

    assert Invocations.raw_frames(inv) == frames and Invocations.log(inv) == log

    # Rollups agree with the exact queries on both sides.
    for project <- [from, to] do
      scope = Scope.new("90d", project.id)
      assert Dashboard.summary(scope) == Dashboard.exact_summary(scope)
    end

    assert Repo.exists?(from t in TagKey, where: t.project_id == ^to.id)

    # The source's copies are orphans now; the target's stay.
    old = DateTime.add(DateTime.utc_now(), -2, :hour)
    Repo.update_all(Blobs.Blob, set: [inserted_at: old])
    Blobs.prune_orphans()
    refute Blobs.get(from, notes.digest)
    assert Blobs.exists?(to, notes.digest) and Blobs.exists?(to, inv.raw_blob)

    # Moving again finds nothing; moving back copies the pruned blobs again.
    assert {:ok, %{builds: 0}} = Move.builds(from, to, "status:failed")
    assert {:ok, %{builds: 1, blobs: 4}} = Move.builds(to, from, "")
    assert Blobs.exists?(from, notes.digest)
  end

  test "never moves a live build; refuses bad input", %{ctx: ctx, from: from} do
    id = ingest_fixture!("flaky_test", ctx)
    Repo.update_all(from(i in Invocation, where: i.id == ^id), set: [status: "in_progress"])
    {:ok, to} = Projects.create_project(%{slug: "live-target", name: "Live"})

    assert {:ok, %{builds: 0}} = Move.builds(from, to, "")
    assert {:error, :same_project} = Move.builds(from, from, "")
    # An unparsable query must fail, never match everything.
    assert {:error, {:bad_query, _}} = Move.builds(from, to, "status:(")
    assert {:error, {:bad_query, _}} = Move.builds(from, to, "   ")
    assert {:error, :no_source} = Conveyor.Release.move_builds("nope", "x", "")
  end
end
