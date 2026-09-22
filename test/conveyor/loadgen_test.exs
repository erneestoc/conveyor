defmodule Conveyor.LoadgenTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Ingest.Verify
  alias Conveyor.Loadgen
  alias Conveyor.Loadgen.CLI
  alias Conveyor.Projects

  setup %{project: project} do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "loadgen"})
    %{key: plaintext}
  end

  test "generates load, injects chaos and reports latencies", %{grpc_port: port, key: key} do
    :telemetry.attach(
      "loadgen-test-ack",
      [:conveyor, :ingest, :ack],
      fn _, m, _, pid -> send(pid, {:ack_metric, m}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("loadgen-test-ack") end)

    report =
      Loadgen.run(
        fixtures: [
          Path.join([File.cwd!(), "test/fixtures/bep", "analysis_failure.bep"]),
          Path.join([File.cwd!(), "test/fixtures/bep", "build_failure.bep"])
        ],
        hosts: ["127.0.0.1:#{port}", "127.0.0.1:#{port}"],
        api_key: key,
        streams: 3,
        builds: 4,
        drop_after: 2,
        duplicate_every: 3,
        jitter_ms: 5
      )

    assert %{builds_total: 4, builds_ok: 4, builds_failed: 0, missing_acks: 0, streams: 3} =
             report

    assert report.events > 0 and report.events_per_second > 0 and report.builds_per_minute > 0
    assert %{p50: p50, p99: p99, max: max, count: n} = report.ack_latency_ms
    assert n > 0 and p50 <= p99 and p99 <= max
    assert report.build_duration_ms.count == 4

    for %{id: id, sent: sent} <- report.invocations do
      :ok = await_worker_exit(id)
      assert :ok = Verify.check(id, sent - 1)
    end

    assert_receive {:ack_metric, %{latency_us: us, count: 1}} when us >= 0
    assert Loadgen.format(report) =~ "4/4 ok"

    # Duration-bounded runs stop on time.
    quick =
      Loadgen.run(
        fixtures: [Path.join([File.cwd!(), "test/fixtures/bep", "analysis_failure.bep"])],
        hosts: ["127.0.0.1:#{port}"],
        api_key: key,
        streams: 1,
        duration_ms: 1
      )

    assert quick.builds_total <= 2
    for %{id: id} <- quick.invocations, do: :ok = await_worker_exit(id)
  end

  test "retries a build on another host with the same invocation id", %{
    grpc_port: port,
    key: key
  } do
    # The first host does not exist; the retry lands on the real server and the build
    # completes with every event acked once.
    report =
      Loadgen.run(
        fixtures: [Path.join([File.cwd!(), "test/fixtures/bep", "analysis_failure.bep"])],
        hosts: ["127.0.0.1:1", "127.0.0.1:#{port}"],
        api_key: key,
        streams: 1,
        builds: 1,
        retries: 2
      )

    assert %{builds_ok: 1, builds_failed: 0, missing_acks: 0, retried_builds: 1} = report
    [%{id: id, sent: sent}] = report.invocations
    :ok = await_worker_exit(id)
    assert :ok = Verify.check(id, sent - 1)
    assert Loadgen.format(report) =~ "1 builds retried"

    # Without retries the dead host is a failed build.
    report =
      Loadgen.run(
        fixtures: [Path.join([File.cwd!(), "test/fixtures/bep", "analysis_failure.bep"])],
        hosts: ["127.0.0.1:1"],
        api_key: key,
        streams: 1,
        builds: 1
      )

    assert %{builds_failed: 1, retried_builds: 0} = report
  end

  test "pre-encoded fixtures replay identically" do
    events =
      Conveyor.Bep.Fixture.read!(
        Path.join([File.cwd!(), "test/fixtures/bep", "analysis_failure.bep"])
      )

    pre = Conveyor.Bep.Replay.pre_encode(events)
    assert Enum.count(pre, &match?({:encoded, _}, &1)) == length(events) - 2
    sid = %Google.Devtools.Build.V1.StreamId{build_id: "b", invocation_id: "i", component: :TOOL}

    for {a, b} <- Enum.zip(events, pre) do
      assert Conveyor.Bep.Replay.ordered_event(sid, 1, a).event.event ==
               Conveyor.Bep.Replay.ordered_event(sid, 1, b).event.event
    end
  end

  test "reports failures without raising", %{key: key} do
    report =
      Loadgen.run(
        fixtures: ["test/fixtures/bep/analysis_failure.bep"],
        hosts: ["127.0.0.1:1"],
        api_key: key,
        streams: 1,
        builds: 2
      )

    assert %{builds_ok: 0, builds_failed: 2, events: 0} = report
    assert report.ack_latency_ms == %{p50: nil, p90: nil, p99: nil, max: nil, count: 0}
    assert Loadgen.format(report) =~ "FAILED analysis_failure.bep"
    assert_raise ArgumentError, fn -> Loadgen.run(fixtures: ["nope/*.bep"]) end
    assert Loadgen.percentiles([1, 2, 3, 4]) == %{p50: 3, p90: 4, p99: 4, max: 4, count: 4}
  end

  test "the CLI parses options and drives a run", %{grpc_port: port, key: key} do
    opts = CLI.loadgen_opts(hosts: "a:1,b:2", streams: 4, duration_s: 2, drop_after: 3)

    assert opts[:hosts] == ["a:1", "b:2"] and opts[:builds] == 20 and opts[:duration_ms] == 2000 and
             opts[:drop_after] == 3

    assert CLI.loadgen_opts([])[:streams] == 10
    assert CLI.loadgen_opts([])[:tls] == false and CLI.loadgen_opts(tls: true)[:tls] == true

    report_path =
      Path.join(System.tmp_dir!(), "loadgen-#{System.unique_integer([:positive])}.json")

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        CLI.main(
          ~w(--hosts 127.0.0.1:#{port} --api-key #{key} --fixtures test/fixtures/bep/analysis_failure.bep --streams 2 --builds 2 --report #{report_path})
        )
      end)

    assert out =~ "2/2 ok"

    assert %{"builds_ok" => 2, "invocations" => invocations} =
             report_path |> File.read!() |> Jason.decode!()

    for %{"id" => id} <- invocations, do: :ok = await_worker_exit(id)

    assert catch_exit(CLI.main(["--help"])) == {:shutdown, 0}
    assert catch_exit(CLI.main(["--bogus"])) == {:shutdown, 1}

    failing =
      ExUnit.CaptureIO.capture_io(fn ->
        assert catch_exit(
                 CLI.main(
                   ~w(--hosts 127.0.0.1:1 --api-key #{key} --fixtures test/fixtures/bep/analysis_failure.bep --streams 1 --builds 1 --verify)
                 )
               ) == {:shutdown, 1}
      end)

    assert failing =~ "FAILED"
  end
end
