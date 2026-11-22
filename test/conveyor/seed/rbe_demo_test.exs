defmodule Conveyor.Seed.RbeDemoTest do
  use ConveyorWeb.ConnCase, async: false

  alias Conveyor.Accounts.Scope
  alias Conveyor.Projects
  alias Conveyor.Rbe.Groups
  alias Conveyor.Seed.RbeDemo
  alias ConveyorWeb.RbeReport

  # Uploads through the endpoint in process; the first log is refused once, as when the
  # event stream is not committed yet; the parse queue runs after every log.
  defp upload(path, key, body) do
    if String.contains?(path, "/artifacts/") and Process.put(:refused_once, true) == nil do
      404
    else
      status =
        build_conn()
        |> put_req_header("x-api-key", key)
        |> put_req_header("content-type", "application/octet-stream")
        |> put(path, body)
        |> Map.fetch!(:status)

      Oban.drain_queue(queue: :parse)
      status
    end
  end

  test "the mix task uploads the demo; the pages then show every case it is made for" do
    Application.put_env(:conveyor, :rbe_demo_hooks, put: &upload/3)
    on_exit(fn -> Application.delete_env(:conveyor, :rbe_demo_hooks) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Conveyor.Seed.run(["--rbe-demo"])
    assert_received {:mix_shell, :info, ["rbe-demo-empty: 3 builds"]}
    assert_received {:mix_shell, :info, ["rbe-demo-ios: 13 builds"]}

    admin = %Scope{admin?: true}
    ios = RbeReport.project(admin, Projects.get_project_by_slug("rbe-demo-ios"), "7d")
    assert ios.coverage == %{builds: 13, logs: 13}
    # shards race on what changed, the nightly build repeats what was finished
    assert ios.racing.remotable.n > 100
    assert ios.racing.local.n > 0
    assert ios.racing.uncertain.racing.n > 0
    assert ios.cache.same_project.n >= 26
    assert ios.cache.cross_project.n == 0
    assert ios.cache.hits > 0
    assert ios.near.n >= 1
    assert ios.nondet.n > 0
    assert ios.not_dedupable.failed.n == 1
    assert ios.not_dedupable.uncacheable.n == 12
    assert ios.keys["fallback"] > 0
    assert ios.cores_coverage.exact_share > 0.3 and ios.cores_coverage.exact_share < 0.9

    assert Enum.map(ios.pipelines, & &1.value) |> Enum.sort() ==
             ~w(ios-1001 ios-1002 ios-1003 ios-1004)

    group = Groups.get_by_name("rbe-demo-monorepo")
    mono = RbeReport.group(admin, group, "7d")
    assert mono.members == 3
    assert mono.coverage == %{builds: 8, logs: 8}
    assert mono.cache.cross_project.n > 0
    assert mono.cache.same_project.n > 0
    assert mono.racing.cross_project.n == 6
    assert mono.cache.hits > 0
    refute mono.keys["fallback"]

    empty = RbeReport.project(admin, Projects.get_project_by_slug("rbe-demo-empty"), "7d")
    assert empty.coverage == %{builds: 3, logs: 0}

    # a second run replaces the first: the same numbers, not twice the builds
    Process.delete(:refused_once)
    assert %{"rbe-demo-ios" => 13} = RbeDemo.run(put: &upload/3)
    again = RbeReport.project(admin, Projects.get_project_by_slug("rbe-demo-ios"), "7d")
    assert again.coverage == %{builds: 13, logs: 13}
    assert again.racing.remotable.n == ios.racing.remotable.n
  end

  test "without a server the upload says so" do
    assert_raise RuntimeError, ~r/is the server running/, fn ->
      RbeDemo.run(url: "http://127.0.0.1:1", await: fn _ -> :ok end)
    end
  end
end
