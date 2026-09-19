defmodule Conveyor.SeedTest do
  use Conveyor.IngestCase

  import Ecto.Query

  alias Conveyor.Invocations
  alias Conveyor.Invocations.{Invocation, TagKey, Target}
  alias Conveyor.Seed

  test "replays fixtures through the pipeline and spreads them over the last days" do
    project = Conveyor.Projects.ensure_default_project!()
    ids = Seed.replay(project.id, 6, 3, concurrency: 3, seed: {1, 2, 3})
    assert length(ids) == 6
    now = DateTime.utc_now()

    for id <- ids do
      inv = Repo.get!(Invocation, id)
      assert inv.status in ["succeeded", "failed"]
      assert DateTime.compare(inv.started_at, now) == :lt
      assert DateTime.diff(now, inv.started_at, :hour) <= 4 * 24
      assert DateTime.diff(inv.finished_at, inv.started_at, :millisecond) == inv.duration_ms
      assert inv.duration_ms >= 500
      assert inv.user_name in ["ci" | ~w(alice bob carol dave erin frank grace heidi)]
      assert Map.take(inv.tags, ~w(user ci branch team host bazel_version)) |> map_size() == 6
      refute Map.has_key?(inv.tags, "scenario")
      assert inv.tags["host"] == inv.host and inv.workspace_status["BUILD_HOST"] == inv.host
      assert inv.workspace =~ "/acme"

      assert inv.remote_cache_hits + inv.remote_exec + inv.worker_exec + inv.sandbox_exec ==
               inv.actions_executed

      assert Invocations.raw_frames(inv) != []

      # Targets and actions move with the build.
      for t <-
            Repo.all(
              from t in Target, where: t.invocation_id == ^id and not is_nil(t.first_seen_at)
            ) do
        assert abs(DateTime.diff(t.first_seen_at, inv.started_at, :second)) < 600
      end
    end

    # CI builds carry a synthetic remote-execution profile with a summary; builds that
    # referenced the recorded profile get the real one.
    with_profile = Enum.filter(ids, &(Repo.get!(Invocation, &1).profile_status == "available"))
    assert with_profile != []
    summary = Invocations.metrics(Repo.get!(Invocation, hd(with_profile))).profile_summary
    assert summary["event_count"] > 0 and summary["action_phases"] != []

    facets = Repo.all(from t in TagKey, where: t.project_id == ^project.id)
    assert Enum.any?(facets, &(&1.key == "branch"))
    assert Enum.sum(for %{key: "team"} = f <- facets, do: f.count) == 6
  end

  test "big_log ingests a build with a large curses-style log" do
    project = Conveyor.Projects.ensure_default_project!()
    id = Seed.big_log(project.id, 1)
    inv = Repo.get!(Invocation, id)
    assert inv.log_bytes >= 1024 * 1024 and inv.log_lines > 1000
    assert inv.status == "succeeded" and inv.tags["ci"] == "true"
    log = Invocations.log(inv)
    assert log =~ "\e[8A" and log =~ "\e[33mWARNING:"
    assert byte_size(log) == inv.log_bytes
  end

  test "the mix task replays into the default project" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Conveyor.Seed.run([
      "--replay",
      "3",
      "--days",
      "2",
      "--concurrency",
      "2",
      "--big-log",
      "1"
    ])

    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "ingested a 1 MB log build"
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "replayed 3 builds over 2 days"
  end
end
