defmodule ConveyorWeb.Plugs.ForceSSL do
  @moduledoc """
  `Plug.SSL` switched on at runtime by `FORCE_SSL` (`config :conveyor, :force_ssl`), so the
  same release runs behind a layer-7 terminator that sets `x-forwarded-proto` (redirect +
  HSTS) and behind a layer-4 balancer (no redirect). Health paths are never redirected, so
  balancer checks over plain HTTP keep working.
  """
  @behaviour Plug

  @impl true
  def init(_opts) do
    Plug.SSL.init(
      rewrite_on: [:x_forwarded_proto],
      hsts: true,
      host: nil,
      exclude: ["localhost", "127.0.0.1"]
    )
  end

  @impl true
  def call(%Plug.Conn{request_path: "/health" <> _} = conn, _opts), do: conn

  def call(conn, opts) do
    if Application.get_env(:conveyor, :force_ssl, false),
      do: Plug.SSL.call(conn, opts),
      else: conn
  end
end
