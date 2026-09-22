defmodule ConveyorWeb.MetricsControllerTest do
  use ConveyorWeb.ConnCase, async: false

  test "exposes Prometheus metrics, optionally behind a token", %{conn: conn} do
    :telemetry.execute([:conveyor, :ingest, :ack], %{latency_us: 1234, count: 1}, %{})

    :telemetry.execute(
      [:conveyor, :ingest, :writer, :flush],
      %{duration: 1_000_000, batches: 1, events: 5},
      %{shard: 0}
    )

    :telemetry.execute([:conveyor, :ingest, :fenced], %{count: 1}, %{invocation_id: "x"})
    :telemetry.execute([:conveyor, :blobs, :errors], %{count: 1}, %{op: :put})

    # A job waiting since an hour ago shows as queue backlog age.
    job =
      Conveyor.Repo.insert!(
        Oban.Job.new(%{invocation_id: "x"},
          worker: "Conveyor.Workers.ParseExecLog",
          queue: :default,
          scheduled_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )
      )

    # Oban inserts a past scheduled_at as "scheduled" until its stager runs; make it wait.
    Conveyor.Repo.update_all(Oban.Job, set: [state: "available"])
    assert job.state == "scheduled"

    body = conn |> get(~p"/metrics") |> response(200)
    assert body =~ "conveyor_ingest_ack_count"
    # Counters accumulate over the whole test run: at least the events above.
    assert counter(body, "conveyor_ingest_fenced_count") >= 1
    assert counter(body, ~s(conveyor_blobs_errors_count{op="put"})) >= 1
    assert body =~ ~s(conveyor_oban_jobs_count{queue="default",state="available"} 1)
    assert body =~ ~s(conveyor_oban_jobs_count{queue="maintenance",state="executing"} 0)

    [age] =
      Regex.run(~r/conveyor_oban_oldest_available_seconds\{queue="default"\} (\d+)/, body,
        capture: :all_but_first
      )

    assert String.to_integer(age) >= 3599
    assert body =~ ~s(conveyor_oban_oldest_available_seconds{queue="maintenance"} 0)
    assert body =~ "conveyor_ingest_ack_latency_us_bucket"
    assert body =~ "conveyor_ingest_workers_count"
    assert body =~ "conveyor_ingest_writer_flush_duration"

    Application.put_env(:conveyor, :metrics_token, "scrape-me")
    on_exit(fn -> Application.delete_env(:conveyor, :metrics_token) end)
    assert build_conn() |> get(~p"/metrics") |> response(401)
    assert build_conn() |> get(~p"/metrics?token=scrape-me") |> response(200)

    assert build_conn()
           |> put_req_header("authorization", "Bearer scrape-me")
           |> get(~p"/metrics")
           |> response(200)

    assert build_conn()
           |> put_req_header("authorization", "Bearer nope")
           |> get(~p"/metrics")
           |> response(401)
  end

  defp counter(body, series) do
    [value] = Regex.run(~r/^#{Regex.escape(series)} (\d+)/m, body, capture: :all_but_first)
    String.to_integer(value)
  end
end
