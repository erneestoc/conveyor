defmodule ConveyorWeb.HealthController do
  @moduledoc """
  `/health/live` answers as long as the VM runs; `/health/ready` answers 200 only when the
  database responds and the node is not draining, so balancers and Kubernetes stop routing
  new work to a node that is shutting down or has lost its database.
  """
  use ConveyorWeb, :controller

  def live(conn, _params), do: json(conn, %{status: "ok", node: node()})

  def ready(conn, _params) do
    checks = %{database: database_ok?(), draining: Conveyor.Drain.draining?()}
    ready? = checks.database and not checks.draining

    conn
    |> put_status(if ready?, do: 200, else: 503)
    |> json(%{status: if(ready?, do: "ready", else: "not_ready"), node: node(), checks: checks})
  end

  defp database_ok? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Conveyor.Repo, "SELECT 1", [], timeout: 2_000))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
