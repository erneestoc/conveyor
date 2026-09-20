defmodule ConveyorWeb.Plugs.ForceSSLTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias ConveyorWeb.Plugs.ForceSSL

  setup do
    prev = Application.get_env(:conveyor, :force_ssl)
    on_exit(fn -> Application.put_env(:conveyor, :force_ssl, prev) end)
    :ok
  end

  defp call(conn), do: ForceSSL.call(conn, ForceSSL.init([]))

  test "does nothing unless FORCE_SSL is on" do
    Application.put_env(:conveyor, :force_ssl, false)
    conn = conn(:get, "http://conveyor.example.com/dashboard") |> call()
    refute conn.halted
  end

  test "redirects plain http, honours x-forwarded-proto and sends HSTS over https" do
    Application.put_env(:conveyor, :force_ssl, true)
    conn = conn(:get, "http://conveyor.example.com/dashboard?range=7d") |> call()
    assert conn.halted and conn.status == 301

    assert Plug.Conn.get_resp_header(conn, "location") == [
             "https://conveyor.example.com/dashboard?range=7d"
           ]

    conn =
      conn(:get, "http://conveyor.example.com/dashboard")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> call()

    refute conn.halted
    assert [hsts] = Plug.Conn.get_resp_header(conn, "strict-transport-security")
    assert hsts =~ "max-age="
  end

  test "health paths and local hosts are never redirected" do
    Application.put_env(:conveyor, :force_ssl, true)
    refute conn(:get, "http://conveyor.example.com/health/ready") |> call() |> Map.get(:halted)
    refute conn(:get, "http://localhost/dashboard") |> call() |> Map.get(:halted)
  end
end
