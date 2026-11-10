defmodule Conveyor.FakeS3 do
  @moduledoc """
  A minimal S3-compatible server for tests: PUT/GET (with `Range`)/HEAD/DELETE objects and
  DeleteObjects, held in an Agent,
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
      _body when method == "HEAD" -> send_resp(conn, 200, "")
      body -> ranged(conn, body, get_req_header(conn, "range"))
    end
  end

  # DeleteObjects: `POST /<bucket>?delete` with an XML list of keys and a Content-MD5.
  # A key that contains "refuse" is reported as an error, the way S3 reports a denied key.
  defp serve(%{method: "POST", query_string: "delete"} = conn, store) do
    {:ok, body, conn} = read_body(conn)
    [md5] = get_req_header(conn, "content-md5")

    if md5 == Base.encode64(:crypto.hash(:md5, body)) do
      keys = Regex.scan(~r|<Key>(.*?)</Key>|, body, capture: :all_but_first) |> List.flatten()
      {refused, deleted} = Enum.split_with(keys, &String.contains?(&1, "refuse"))
      paths = Enum.map(deleted, &(conn.request_path <> "/" <> &1))
      Agent.update(store, &Map.drop(&1, paths))

      errors =
        Enum.map(refused, fn key ->
          "<Error><Key>#{key}</Key><Code>AccessDenied</Code><Message>Access &amp; Denied</Message></Error>"
        end)

      send_resp(conn, 200, "<DeleteResult>#{errors}</DeleteResult>")
    else
      send_resp(conn, 400, "BadDigest")
    end
  end

  defp serve(%{method: "DELETE"} = conn, store) do
    Agent.update(store, &Map.delete(&1, conn.request_path))
    send_resp(conn, 204, "")
  end

  defp ranged(conn, body, []), do: send_resp(conn, 200, body)

  defp ranged(conn, body, ["bytes=" <> range]) do
    [first, last] = range |> String.split("-") |> Enum.map(&String.to_integer/1)

    if first >= byte_size(body) do
      send_resp(conn, 416, "InvalidRange")
    else
      last = min(last, byte_size(body) - 1)
      send_resp(conn, 206, binary_part(body, first, last - first + 1))
    end
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
