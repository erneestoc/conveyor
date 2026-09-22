defmodule ConveyorWeb.MetricsController do
  @moduledoc """
  Prometheus scrape endpoint. With `METRICS_TOKEN` set, the token (bearer or `?token=`) is
  the only credential; without one, the caller needs an admin session (in open mode
  without `ADMIN_TOKEN` that is everyone, as before). The metrics carry no per-project
  labels, so there is no per-project view: it is admin-only.
  """
  use ConveyorWeb, :controller

  alias Conveyor.Accounts.Scope

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

  defp authorized?(conn, _params, expected) when expected in [nil, ""] do
    conn |> get_session() |> Scope.from_session() |> Map.fetch!(:admin?)
  end

  defp authorized?(conn, params, expected) do
    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> params["token"] || ""
      end

    Plug.Crypto.secure_compare(presented, expected)
  end
end
