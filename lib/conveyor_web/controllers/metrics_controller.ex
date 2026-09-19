defmodule ConveyorWeb.MetricsController do
  @moduledoc "Prometheus scrape endpoint; protected by `METRICS_TOKEN` when one is configured."
  use ConveyorWeb, :controller

  def index(conn, params) do
    expected = Application.get_env(:conveyor, :metrics_token)

    if authorized?(conn, params, expected) do
      ConveyorWeb.Telemetry.measure_ingest()

      conn
      |> put_resp_content_type("text/plain; version=0.0.4", nil)
      |> send_resp(200, ConveyorWeb.Telemetry.scrape())
    else
      conn |> put_resp_content_type("text/plain") |> send_resp(401, "metrics token required")
    end
  end

  defp authorized?(_conn, _params, expected) when expected in [nil, ""], do: true

  defp authorized?(conn, params, expected) do
    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> params["token"] || ""
      end

    Plug.Crypto.secure_compare(presented, expected)
  end
end
