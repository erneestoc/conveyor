defmodule Conveyor.Blobs.S3 do
  @moduledoc """
  Blob adapter for S3-compatible object stores (AWS S3, MinIO, Ceph RGW, R2).

  Requests are signed with AWS Signature Version 4 and sent through OTP's `:httpc`, so
  there are no extra dependencies. Options:

    * `:bucket`, `:region` (default `"us-east-1"`)
    * `:endpoint` — base URL for non-AWS stores (`http://minio:9000`); default is the
      regional AWS endpoint
    * `:path_style` — `true` puts the bucket in the path (MinIO default), `false` uses
      virtual-host addressing (AWS default)
    * `:prefix` — key prefix inside the bucket (default `"blobs"`)
    * `:access_key_id`, `:secret_access_key`, `:session_token`
  """
  @behaviour Conveyor.Blobs.Adapter

  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @impl true
  def put(digest, enum, opts) do
    body = enum |> Enum.to_list() |> IO.iodata_to_binary()
    headers = [{"content-type", Keyword.get(opts, :content_type) || "application/octet-stream"}]

    case request(:put, digest, opts, headers, body, digest) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers, body} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stream(digest, opts) do
    tmp =
      Path.join(System.tmp_dir!(), "conveyor-s3-#{digest}-#{System.unique_integer([:positive])}")

    case request(:get, digest, opts, [], nil, @empty_sha256, stream: tmp) do
      {:ok, :saved_to_file} -> {:ok, file_stream(tmp, Keyword.get(opts, :chunk_size, 64 * 1024))}
      {:ok, 404, _headers, _body} -> {:error, :not_found}
      {:ok, status, _headers, body} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(digest, opts) do
    match?(
      {:ok, status, _, _} when status in 200..299,
      request(:head, digest, opts, [], nil, @empty_sha256)
    )
  end

  @impl true
  def delete(digest, opts) do
    case request(:delete, digest, opts, [], nil, @empty_sha256) do
      {:ok, status, _headers, _body} when status in [200, 202, 204, 404] -> :ok
      {:ok, status, _headers, body} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A file stream that removes the temporary download once it has been consumed.
  defp file_stream(path, chunk_size) do
    Stream.resource(
      fn -> File.open!(path, [:read, :binary]) end,
      fn io ->
        case IO.binread(io, chunk_size) do
          data when is_binary(data) and data != "" -> {[data], io}
          _ -> {:halt, io}
        end
      end,
      fn io ->
        File.close(io)
        File.rm(path)
      end
    )
  end

  defp request(method, digest, opts, headers, body, payload_hash, httpc_opts \\ []) do
    url = url(digest, opts)
    uri = URI.parse(url)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    headers =
      [
        {"host", host_header(uri)},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date(now)}
      ] ++
        headers ++ session_header(opts)

    authorization = sign(method, uri, headers, payload_hash, now, opts)
    all = [{"authorization", authorization} | headers]

    charlist_headers =
      for {k, v} <- all, k != "host", do: {String.to_charlist(k), String.to_charlist(v)}

    req =
      if body,
        do: {String.to_charlist(url), charlist_headers, ~c"application/octet-stream", body},
        else: {String.to_charlist(url), charlist_headers}

    http_opts = [timeout: Keyword.get(opts, :timeout_ms, 60_000), connect_timeout: 10_000]

    result =
      :httpc.request(method, req, http_opts, [body_format: :binary] ++ stream_opt(httpc_opts))

    case result do
      {:ok, :saved_to_file} -> {:ok, :saved_to_file}
      {:ok, {{_, status, _}, resp_headers, resp_body}} -> {:ok, status, resp_headers, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_opt(stream: path), do: [stream: String.to_charlist(path)]
  defp stream_opt(_), do: []

  defp session_header(opts) do
    case Keyword.get(opts, :session_token) do
      nil -> []
      token -> [{"x-amz-security-token", token}]
    end
  end

  @doc "Object URL for a digest under the configured bucket, prefix and addressing style."
  def url(digest, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    region = Keyword.get(opts, :region, "us-east-1")
    key = Path.join(Keyword.get(opts, :prefix, "blobs"), digest)

    case {Keyword.get(opts, :endpoint), Keyword.get(opts, :path_style, false)} do
      {nil, false} ->
        "https://#{bucket}.s3.#{region}.amazonaws.com/#{key}"

      {nil, true} ->
        "https://s3.#{region}.amazonaws.com/#{bucket}/#{key}"

      {endpoint, false} ->
        "#{String.trim_trailing(endpoint, "/")}/#{key}" |> host_prefixed(bucket)

      {endpoint, true} ->
        "#{String.trim_trailing(endpoint, "/")}/#{bucket}/#{key}"
    end
  end

  defp host_prefixed(url, bucket) do
    uri = URI.parse(url)
    URI.to_string(%{uri | host: "#{bucket}.#{uri.host}"})
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port in [nil, 80, 443] and
         ((scheme == "http" and port != 443) or (scheme == "https" and port != 80)),
       do: host,
       else: "#{host}:#{port}"
  end

  @doc """
  AWS Signature Version 4 `Authorization` header value for a request whose headers
  (lowercase names) are all signed.
  """
  @spec sign(atom(), URI.t(), [{String.t(), String.t()}], String.t(), DateTime.t(), keyword()) ::
          String.t()
  def sign(method, %URI{} = uri, headers, payload_hash, now, opts) do
    region = Keyword.get(opts, :region, "us-east-1")
    access_key = Keyword.fetch!(opts, :access_key_id)
    secret = Keyword.fetch!(opts, :secret_access_key)
    date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{date}/#{region}/s3/aws4_request"

    sorted =
      headers |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end) |> Enum.sort()

    signed_headers = sorted |> Enum.map(&elem(&1, 0)) |> Enum.join(";")
    canonical_headers = Enum.map_join(sorted, "", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical_request =
      Enum.join(
        [
          method |> Atom.to_string() |> String.upcase(),
          canonical_path(uri.path || "/"),
          canonical_query(uri.query),
          canonical_headers,
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    string_to_sign =
      Enum.join(["AWS4-HMAC-SHA256", amz_date(now), scope, hex_sha256(canonical_request)], "\n")

    signing_key =
      ("AWS4" <> secret)
      |> hmac(date)
      |> hmac(region)
      |> hmac("s3")
      |> hmac("aws4_request")

    signature = signing_key |> hmac(string_to_sign) |> Base.encode16(case: :lower)

    "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  defp canonical_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &aws_encode/1)
  end

  defp canonical_query(nil), do: ""

  defp canonical_query(query) do
    query
    |> URI.decode_query()
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} ->
      aws_encode(k) <> "=" <> aws_encode(v)
    end)
  end

  defp aws_encode(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp amz_date(now), do: Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
  defp hex_sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
