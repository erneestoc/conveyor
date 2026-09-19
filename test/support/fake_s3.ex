defmodule Conveyor.FakeS3 do
  @moduledoc """
  A minimal S3-compatible server for tests: PUT/GET/HEAD/DELETE objects held in an Agent,
  verifying that every request carries a well-formed SigV4 `Authorization` header whose
  signature matches what `Conveyor.Blobs.S3.sign/6` produces for the same credentials.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    store = Keyword.fetch!(opts, :store)
    creds = Keyword.fetch!(opts, :creds)

    if authorized?(conn, creds) do
      serve(conn, store)
    else
      send_resp(conn, 403, "SignatureDoesNotMatch")
    end
  end

  defp authorized?(conn, creds) do
    [auth] = get_req_header(conn, "authorization")

    with "AWS4-HMAC-SHA256 " <> _ <- auth,
         [_, signed] <- Regex.run(~r/SignedHeaders=([^,]+)/, auth),
         [payload_hash] <- get_req_header(conn, "x-amz-content-sha256"),
         [amz_date] <- get_req_header(conn, "x-amz-date"),
         {:ok, now, _} <- DateTime.from_iso8601(iso(amz_date)) do
      headers =
        signed
        |> String.split(";")
        |> Enum.map(fn name -> {name, conn |> get_req_header(name) |> List.first() || ""} end)

      uri = %URI{path: conn.request_path, query: conn.query_string}
      method = conn.method |> String.downcase() |> String.to_atom()
      Conveyor.Blobs.S3.sign(method, uri, headers, payload_hash, now, creds) == auth
    else
      _ -> false
    end
  end

  defp iso(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           mi::binary-size(2), s::binary-size(2), "Z">>
       ),
       do: "#{y}-#{m}-#{d}T#{h}:#{mi}:#{s}Z"

  defp iso(_), do: "invalid"

  defp serve(%{method: "PUT"} = conn, store) do
    {:ok, body, conn} = read_body(conn, length: 100_000_000)
    Agent.update(store, &Map.put(&1, conn.request_path, body))
    send_resp(conn, 200, "")
  end

  defp serve(%{method: method} = conn, store) when method in ["GET", "HEAD"] do
    case Agent.get(store, &Map.get(&1, conn.request_path)) do
      nil -> send_resp(conn, 404, "NoSuchKey")
      body -> send_resp(conn, 200, if(method == "HEAD", do: "", else: body))
    end
  end

  defp serve(%{method: "DELETE"} = conn, store) do
    Agent.update(store, &Map.delete(&1, conn.request_path))
    send_resp(conn, 204, "")
  end

  @doc "Starts the fake server on a free port; returns `{port, store_agent}`."
  def start(creds) do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    port = Conveyor.GrpcCase.free_port()

    {:ok, _} =
      Bandit.start_link(
        plug: {__MODULE__, store: store, creds: creds},
        port: port,
        ip: {127, 0, 0, 1}
      )

    {port, store}
  end
end
