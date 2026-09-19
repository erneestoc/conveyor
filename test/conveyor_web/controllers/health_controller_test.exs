defmodule ConveyorWeb.HealthControllerTest do
  use ConveyorWeb.ConnCase, async: false

  test "liveness and readiness reflect draining", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health/live") |> json_response(200)

    assert %{"status" => "ready", "checks" => %{"database" => true, "draining" => false}} =
             build_conn() |> get(~p"/health/ready") |> json_response(200)

    Conveyor.Drain.start()
    on_exit(fn -> Conveyor.Drain.stop() end)

    assert %{"status" => "not_ready", "checks" => %{"draining" => true}} =
             build_conn() |> get(~p"/health/ready") |> json_response(503)

    assert Conveyor.Drain.run(0) == :ok
    assert Conveyor.Drain.timeout_ms() == 30_000
  end
end
