defmodule ConveyorWeb.HealthController do
  @moduledoc """
  `/health/live` answers as long as the VM runs; `/health/ready` answers 200 while
  `Conveyor.Admission.ready/0` says a balancer should send this node new connections: it
  has reached its database, it is not draining, and it is not the one overloaded node of a
  cluster that has room elsewhere. The answer comes from the admission cell: no query per
  probe.
  """
  use ConveyorWeb, :controller

  def live(conn, _params), do: json(conn, %{status: "ok", node: node()})

  def ready(conn, _params) do
    %{ready: ready?, state: state, checks: checks} = Conveyor.Admission.ready()

    conn
    |> put_status(if ready?, do: 200, else: 503)
    |> json(%{
      status: if(ready?, do: "ready", else: "not_ready"),
      node: node(),
      admission: state,
      checks: checks
    })
  end
end
