defmodule ConveyorWeb.HealthControllerTest do
  use ConveyorWeb.ConnCase, async: false

  @moduletag :capture_log

  alias Conveyor.Admission
  alias Conveyor.Admission.Sampler

  setup do
    on_exit(fn ->
      Admission.resume()
      Sampler.inject([])
    end)
  end

  defp ready(status), do: build_conn() |> get(~p"/health/ready") |> json_response(status)

  test "liveness and readiness reflect draining", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health/live") |> json_response(200)

    assert %{
             "status" => "ready",
             "admission" => "normal",
             "checks" => %{"database" => true, "draining" => false, "overloaded" => false}
           } = ready(200)

    assert Admission.drain(0) == :ok
    assert %{"status" => "not_ready", "checks" => %{"draining" => true}} = ready(503)
  end

  test "an overloaded node stays ready unless the rest of the cluster has room" do
    config = [unready_after_ms: 0, unready_min_ms: 0, peer_ttl_ms: 60_000]

    # Alone, or with every node under the same pressure: it sheds at the doors and stays.
    Sampler.inject(signals: %{oldest_ms: 9_000}, config: config)
    assert %{"admission" => "shedding", "checks" => %{"overloaded" => true}} = ready(200)

    send(Sampler, {:admission, :a@elsewhere, 2, true})
    send(Sampler, {:admission, :b@elsewhere, 2, true})
    Sampler.sample()
    assert %{"status" => "ready"} = ready(200)

    # The others are fine: this node is the outlier and leaves the balancer.
    send(Sampler, {:admission, :a@elsewhere, 0, true})
    send(Sampler, {:admission, :b@elsewhere, 0, true})
    Sampler.sample()

    assert %{"status" => "not_ready", "checks" => %{"overloaded" => true, "draining" => false}} =
             ready(503)
  end

  test "a node that has lost its database is not ready" do
    Sampler.inject(probe: fn -> :error end, config: [probe_ms: 5, probe_failures: 1])
    assert %{"status" => "not_ready", "checks" => %{"database" => false}} = ready(503)
  end
end
