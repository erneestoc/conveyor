defmodule ConveyorWeb.MetricsControllerTest do
  use ConveyorWeb.ConnCase, async: false

  test "exposes Prometheus metrics, optionally behind a token", %{conn: conn} do
    :telemetry.execute([:conveyor, :ingest, :ack], %{latency_us: 1234, count: 1}, %{})

    :telemetry.execute(
      [:conveyor, :ingest, :writer, :flush],
      %{duration: 1_000_000, batches: 1, events: 5},
      %{shard: 0}
    )

    body = conn |> get(~p"/metrics") |> response(200)
    assert body =~ "conveyor_ingest_ack_count"
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
end
