defmodule Conveyor.QueryTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Invocations
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Projects
  alias Conveyor.Query
  alias Conveyor.Repo

  @now ~U[2026-09-18 12:00:00.000000Z]

  setup do
    project = Projects.ensure_default_project!()

    rows = [
      %{
        status: "succeeded",
        command: "test",
        user_name: "alice",
        host: "mac-1",
        bazel_version: "9.2.0",
        patterns: ["//app/...", "//lib:all"],
        duration_ms: 90_000,
        tests_total: 5,
        tests_failed: 0,
        started_at: DateTime.add(@now, -1, :hour),
        tags: %{"ci" => "false", "team" => "infra", "shard" => "3"},
        exit_code_name: "SUCCESS"
      },
      %{
        status: "failed",
        command: "build",
        user_name: "Bob",
        host: "ci-42",
        bazel_version: "8.3.1",
        patterns: ["//server:all"],
        duration_ms: 600_000,
        tests_total: 0,
        tests_failed: 0,
        started_at: DateTime.add(@now, -3, :day),
        tags: %{"ci" => "true", "team" => "backend", "shard" => "12", "branch" => "release/1.2"},
        exit_code_name: "BUILD_FAILURE"
      },
      %{
        status: "in_progress",
        command: "test",
        user_name: nil,
        host: nil,
        bazel_version: nil,
        patterns: [],
        duration_ms: nil,
        tests_total: 0,
        tests_failed: 0,
        started_at: DateTime.add(@now, -5, :minute),
        tags: %{},
        exit_code_name: nil
      }
    ]

    invs =
      for attrs <- rows do
        Repo.insert!(
          struct(%Invocation{id: Conveyor.Bep.Replay.uuid(), project_id: project.id}, attrs)
        )
      end

    %{invs: invs, ids: Enum.map(invs, & &1.id)}
  end

  # Every query is checked against the database and against the in-memory evaluator.
  defp ids_for(q, invs) do
    {:ok, ast} = Query.parse(q)
    db = Invocations.list(query: ast, now: @now, limit: 100) |> Enum.map(& &1.id) |> Enum.sort()

    mem =
      invs |> Enum.filter(&Query.matches?(ast, &1, now: @now)) |> Enum.map(& &1.id) |> Enum.sort()

    assert db == mem,
           "database and in-memory results differ for #{inspect(q)}: #{inspect(db)} vs #{inspect(mem)}"

    db
  end

  test "column and tag queries agree between SQL and in-memory evaluation", %{
    invs: invs,
    ids: [ok, failed, running]
  } do
    assert ids_for("status:succeeded", invs) == [ok]
    assert ids_for("status:running", invs) == [running]
    assert ids_for("-status:succeeded", invs) == Enum.sort([failed, running])
    assert ids_for("status:(failed,running)", invs) == Enum.sort([failed, running])
    assert ids_for("status!=failed", invs) == Enum.sort([ok, running])
    assert ids_for("user:ALICE", invs) == [ok]
    assert ids_for("user:*", invs) == Enum.sort([ok, failed])
    assert ids_for("user!=alice", invs) == Enum.sort([failed, running])
    assert ids_for("host~^ci-", invs) == [failed]
    assert ids_for("bazel:9.2.0", invs) == [ok]
    assert ids_for("command:test", invs) == Enum.sort([ok, running])
    assert ids_for("exit:BUILD_FAILURE", invs) == [failed]
    assert ids_for("pattern://lib:all", invs) == [ok]
    assert ids_for("pattern!=//lib:all", invs) == Enum.sort([failed, running])
    assert ids_for("pattern~server", invs) == [failed]
    assert ids_for("pattern:(//server:all,//x)", invs) == [failed]
    assert ids_for("pattern:*", invs) == Enum.sort([ok, failed])
    assert ids_for("duration>5m", invs) == [failed]
    assert ids_for("duration<=90", invs) == [ok]
    assert ids_for("duration:1m30s", invs) == [ok]
    assert ids_for("duration!=1m30s", invs) == Enum.sort([failed, running])
    assert ids_for("duration:*", invs) == Enum.sort([ok, failed])
    assert ids_for("duration:(90,600)", invs) == Enum.sort([ok, failed])
    assert ids_for("tests>=5", invs) == [ok]
    assert ids_for("tests_failed<1", invs) == Enum.sort([ok, failed, running])
    assert ids_for("started>-24h", invs) == Enum.sort([ok, running])
    assert ids_for("started<2026-09-17", invs) == [failed]
    assert ids_for("started>=2026-09-18T11:00:00Z", invs) == Enum.sort([ok, running])
    assert ids_for("ci:true", invs) == [failed]
    assert ids_for("ci!=true", invs) == Enum.sort([ok, running])
    assert ids_for("ci:*", invs) == Enum.sort([ok, failed])
    assert ids_for("-ci:*", invs) == [running]
    assert ids_for("team:(infra,backend)", invs) == Enum.sort([ok, failed])
    assert ids_for("team!=(infra,x)", invs) == Enum.sort([failed, running])
    assert ids_for("branch~^release/", invs) == [failed]
    assert ids_for("shard>5", invs) == [failed]
    assert ids_for("shard<=3", invs) == [ok]
    assert ids_for("shard>=3", invs) == Enum.sort([ok, failed])
    assert ids_for("shard<100", invs) == Enum.sort([ok, failed])
    assert ids_for("team>5", invs) == []
    assert ids_for("alice", invs) == [ok]
    assert ids_for("//server", invs) == [failed]
    assert ids_for("infra", invs) == [ok]
    assert ids_for("ci-42", invs) == [failed]
    assert ids_for("nothing-matches-this", invs) == []
    assert ids_for(~s("release/1.2"), invs) == [failed]
    assert ids_for("ci:false team:infra command:test", invs) == [ok]
    assert ids_for("", invs) == Enum.sort([ok, failed, running])
  end

  test "unparseable values and unsupported operators match nothing", %{invs: invs} do
    assert ids_for("duration>abc", invs) == []
    assert ids_for("started>soon", invs) == []
    assert ids_for("user>x", invs) == []
    assert ids_for("pattern>x", invs) == []
    assert ids_for("tests~5", invs) == []
    assert ids_for("shard>x", invs) == []
    assert ids_for("duration:(abc)", invs) == []
    assert ids_for(~s(host~"["), invs) == []
    assert ids_for(~s(pattern~"["), invs) == []
    assert ids_for(~s(team~"["), invs) == []
  end

  test "helpers" do
    assert "status" in Query.builtin_keys()
    assert Query.parse!("bad:") == []
    assert Query.parse!("a:b") == [%{neg: false, key: "a", op: :eq, value: "b"}]
    assert Query.to_query_string(Query.parse!("a:b -c:d")) == "a:b -c:d"
  end

  test "facets aggregate tag keys", %{invs: _} do
    project = Projects.ensure_default_project!()
    now = DateTime.utc_now()

    Repo.insert_all(Conveyor.Invocations.TagKey, [
      %{project_id: project.id, key: "ci", value: "true", count: 5, last_seen_at: now},
      %{project_id: project.id, key: "ci", value: "false", count: 2, last_seen_at: now},
      %{project_id: project.id, key: "team", value: "infra", count: 1, last_seen_at: now}
    ])

    assert [
             %{key: "ci", total: 7, values: [{"true", 5}, {"false", 2}], more: 0},
             %{key: "team", total: 1}
           ] = Invocations.facets(project.id)

    assert [%{key: "ci", values: [{"true", 5}], more: 1} | _] = Invocations.facets(nil, values: 1)
    assert Invocations.facets(-1) == []

    assert Conveyor.Projects.Segments.for_project(project) ==
             Conveyor.Projects.Segments.defaults()

    assert Conveyor.Projects.Segments.for_project(%{
             project
             | settings: %{"segments" => [%{"name" => "X", "query" => "x:1"}]}
           }) == [%{"name" => "X", "query" => "x:1"}]
  end
end
