defmodule ConveyorWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates HTTP API requests with an API key (`x-api-key: <key>` or
  `Authorization: Bearer <key>`) carrying the required scope, and assigns `:api_key`
  (with its project preloaded).
  """
  import Plug.Conn

  alias Conveyor.Projects

  def init(opts), do: Keyword.fetch!(opts, :scope)

  def call(conn, scope) do
    with {:ok, plaintext} <- extract(conn),
         {:ok, key} <- Projects.verify_api_key(plaintext),
         true <- scope in key.scopes || {:error, :scope} do
      Projects.touch_api_key(key, conn.remote_ip |> :inet.ntoa() |> to_string())
      assign(conn, :api_key, key)
    else
      {:error, :scope} ->
        reject(conn, 403, "API key lacks the #{scope} scope")

      {:error, reason} when reason in [:revoked, :expired] ->
        reject(conn, 403, "API key #{reason}")

      {:error, :missing} ->
        reject(conn, 401, "missing API key: send x-api-key or Authorization: Bearer")

      {:error, _} ->
        reject(conn, 401, "invalid API key")
    end
  end

  defp extract(conn) do
    case {get_req_header(conn, "x-api-key"), get_req_header(conn, "authorization")} do
      {[key | _], _} when key != "" -> {:ok, key}
      {_, [auth | _]} -> bearer(auth)
      _ -> {:error, :missing}
    end
  end

  defp bearer(<<b, e, a, r, e2, r2, " ", key::binary>>)
       when <<b, e, a, r, e2, r2>> in ["Bearer", "bearer"],
       do: {:ok, key}

  defp bearer(_), do: {:error, :missing}

  defp reject(conn, status, message) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{errors: %{detail: message}})
    |> halt()
  end
end
