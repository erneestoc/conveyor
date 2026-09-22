defmodule Conveyor.BenchTest do
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Bench
  alias Conveyor.Loadgen
  alias Conveyor.Projects

  setup %{project: project} do
    {:ok, _key, plaintext} = Projects.create_api_key(project, %{name: "bench"})
    %{key: plaintext}
  end

  test "measures a run in-process and writes a report", %{grpc_port: port, key: key} do
    dir =
      Path.join(System.tmp_dir!(), "conveyor-bench-test-#{System.unique_integer([:positive])}")

    fixture = Path.join([File.cwd!(), "test/fixtures/bep", "analysis_failure.bep"])

    # The generator runs in this VM (the real harness spawns `mix conveyor.loadgen`).
    runner = fn opts ->
      report =
        Loadgen.run(
          fixtures: [fixture],
          hosts: ["127.0.0.1:#{port}"],
          api_key: key,
          streams: opts[:streams],
          builds: opts[:builds]
        )

      {report |> Jason.encode!() |> Jason.decode!(), "ok", 0}
    end

    report =
      Bench.run(
        label: "test",
        streams: 2,
        builds: 3,
        runner: runner,
        results_dir: dir,
        settle_ms: 200,
        settle_timeout_ms: 0,
        sample_ms: 20,
        notes: "unit test"
      )

    assert report.label == "test"
    assert report.loadgen["builds_ok"] == 3
    assert report.headline.events_per_s > 0
    # WAL statistics are reported at commit; the sandbox never commits.
    assert report.headline.wal_bytes_per_event >= 0
    assert report.postgres.xacts >= 0
    assert report.writer.count > 0 and report.writer.fenced == 0
    assert report.app.rss_peak > 0 and is_list(report.app.memory_by_kind)
    assert report.app.reductions_by_kind != []
    assert report.verify.checked == 3 and report.verify.failed == 0
    assert File.exists?(report[:path])
    assert Jason.decode!(File.read!(report[:path]))["notes"] == "unit test"
    assert Bench.format(report) =~ "3/3 builds"

    # Without a generator report the run is recorded as failed, not crashed.
    broken =
      Bench.run(
        label: "broken",
        runner: fn _ -> {%{}, "boom", 1} end,
        results_dir: dir,
        settle_ms: 0,
        settle_timeout_ms: 0,
        reset: false
      )

    assert broken.loadgen_exit == 1
    assert broken.verify.checked == 0
  end

  test "builds the generator command, summarizes repeats and reads OS counters" do
    args =
      Bench.loadgen_args([streams: 5, builds: 7, delay_ms: 10, grpc_port: 1999], "/tmp/r.json")

    assert args ==
             ~w(conveyor.loadgen --hosts localhost:1999 --streams 5 --report /tmp/r.json --builds 7 --delay-ms 10)

    assert Bench.read_loadgen_report("/nonexistent/report.json", "out", 1)["error"] == "no report"

    paced = Bench.profile_opts("paced", streams: 10)
    assert paced[:streams] == 10 and paced[:delay_ms] == 500

    assert Bench.profile_opts(nil, [])[:builds] == 10_000

    a = %{
      headline: %{events_per_s: 10.0, ack_p99_ms: nil},
      verify: %{failed: 0},
      loadgen: %{"missing_acks" => 0, "builds_failed" => 0}
    }

    b = %{headline: %{events_per_s: 30.0, ack_p99_ms: 5}, verify: %{failed: 1}, loadgen: %{}}
    summary = Bench.summarize_repeats([a, b])
    assert summary =~ "median of 2 runs" and summary =~ "events_per_s" and summary =~ "20.0"
    assert Bench.median([1, 2, 3]) == 2 and Bench.median([]) == nil
    assert Bench.correct?(a) and not Bench.correct?(b)

    assert Bench.cpu_seconds_of([System.pid()]) >= 0
    # This VM as the "postmaster": itself and its port programs are its process tree.
    procs = Bench.pg_process_times(System.pid(), %{})
    assert {first, last} = procs[System.pid()]
    assert first == last and first >= 0
    assert Bench.pg_process_times(nil, %{}) == %{}
    assert Bench.pg_process_times("not-a-pid", %{"x" => {1.0, 2.0}}) == %{"x" => {1.0, 2.0}}
    assert Bench.cpu_seconds_of(["999999999"]) == nil
    assert Bench.docker_cpu_pct(nil) == nil
    assert Bench.docker_cpu_pct("conveyor-bench-no-such-container") == nil

    assert [%{calls: 1, ms: 2.0, toplevel: true, query: "q"}] =
             Bench.statement_rows([[1, 2.0, 3, 4, 5, true, "q"]])
  end

  test "parses ps cpu time" do
    assert Bench.parse_cpu_time("0:01.23") == 1.23
    assert Bench.parse_cpu_time("1:02:03.50") == 3723.5
    assert Bench.parse_cpu_time("2-01:00:00") == 176_400.0
    assert Bench.parse_cpu_time("7.5") == 7.5
  end
end
