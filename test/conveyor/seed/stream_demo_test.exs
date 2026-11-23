defmodule Conveyor.Seed.StreamDemoTest do
  @moduledoc """
  `mix conveyor.seed --stream-demo` against the real gRPC endpoint with API keys: the
  recorded builds land in their projects, and once their keys are merged the pages show
  what each project is made for.
  """
  use Conveyor.IngestCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.Accounts.Scope
  alias Conveyor.Projects
  alias Conveyor.Rbe.Groups
  alias ConveyorWeb.RbeReport

  @moduletag :capture_log

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "the demo: shards of one commit, a group across commits, both sources", %{
    grpc_port: port
  } do
    # The key merge is the server's job; here the queue is drained instead of awaited.
    Application.put_env(:conveyor, :stream_demo_hooks,
      await: fn _ids -> Oban.drain_queue(queue: :parse) end,
      put: fn _url, _path, _key, _name -> 201 end
    )

    on_exit(fn -> Application.delete_env(:conveyor, :stream_demo_hooks) end)
    Mix.Tasks.Conveyor.Seed.run(["--stream-demo", "--grpc", "localhost:#{port}"])
    assert_received {:mix_shell, :info, ["stream-demo-ios: 5 builds"]}
    assert_received {:mix_shell, :info, ["stream-demo-both: 3 builds"]}

    admin = %Scope{admin?: true}
    ios = RbeReport.project(admin, Projects.get_project_by_slug("stream-demo-ios"), "24h")
    assert ios.source == "stream"

    assert %{builds: 5, counts_only_builds: 1, pending_builds: 0, no_commit_builds: 0} =
             ios.stream

    # two machines at once, then two one after the other, all at one commit: exact
    assert ios.stream.same_commit.racing.n > 0 and ios.stream.same_commit.sequential.n > 500
    assert ios.stream.same_commit.duplicate == ios.stream.any_commit.duplicate
    assert ios.stream.targets != [] and ios.stream.mnemonics != []

    mono = RbeReport.group(admin, Groups.get_by_name("stream-demo-monorepo"), "24h")
    assert mono.members == 2
    assert %{builds: 4, no_commit_builds: 1} = mono.stream
    # the warm build's hits and re-runs are the evidence; the cold machine's repeats of
    # the first commit are estimated from them
    assert %{unchanged: %{n: unchanged}, different: %{n: 12}, unknown: %{n: unknown}} =
             mono.stream.estimate.evidence

    assert unchanged > 300 and unknown > 150
    assert mono.stream.same_commit.duplicate.n < mono.stream.estimate.duplicate.n
    assert mono.stream.estimate.duplicate.n <= mono.stream.any_commit.duplicate.n
    assert mono.stream.any_commit.cross_project.n > 0

    # a second run replaces the first
    Mix.Tasks.Conveyor.Seed.run(["--stream-demo", "--grpc", "localhost:#{port}"])
    ios = RbeReport.project(admin, Projects.get_project_by_slug("stream-demo-ios"), "24h")
    assert ios.stream.builds == 5
  end
end
