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
    * `:project_prefix` — the project's own prefix under it (set by `Conveyor.Blobs`;
      absent for blobs stored before prefixes existed)
    * `:access_key_id`, `:secret_access_key`, `:session_token`

  Keyed objects (the raw log) are stored at `<prefix>/<key>`: `put_object/3` is one PUT
  (S3 answers once the object is durable), `get_range/4` one ranged GET,
  `delete_objects/2` one DeleteObjects per 1,000 keys.
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

  defp request(method, digest, opts, headers, body, payload_hash, httpc_opts \\ []),
    do: request_url(method, url(digest, opts), opts, headers, body, payload_hash, httpc_opts)

  defp request_url(method, url, opts, headers, body, payload_hash, httpc_opts) do
    case Conveyor.Aws.credentials(opts) do
      {:ok, creds} ->
        opts =
          Keyword.merge(
            opts,
            Map.to_list(Map.take(creds, [:access_key_id, :secret_access_key, :session_token]))
          )

        do_request(method, url, opts, headers, body, payload_hash, httpc_opts)

      {:error, reason} ->
        {:error, {:credentials, reason}}
    end
  end

  defp do_request(method, url, opts, headers, body, payload_hash, httpc_opts) do
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

  # --- keyed objects ----------------------------------------------------------------------
  # Under the store's prefix, outside every project's: `<prefix>/<key>`.

  @impl true
  def put_object(key, iodata, opts) do
    body = IO.iodata_to_binary(iodata)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    headers = [{"content-type", "application/octet-stream"}]

    case request(:put, key, keyed(opts), headers, body, hash) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers, body} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "One ranged GET."
  @impl true
  def get_range(key, offset, length, opts) do
    range = [{"range", "bytes=#{offset}-#{offset + length - 1}"}]

    case request(:get, key, keyed(opts), range, nil, @empty_sha256) do
      {:ok, status, _headers, body} when status in [200, 206] and byte_size(body) == length ->
        {:ok, body}

      # Fewer bytes than asked for, or a range that starts past the end.
      {:ok, status, _headers, _body} when status in [200, 206, 416] ->
        {:error, :short_read}

      {:ok, 404, _headers, _body} ->
        {:error, :not_found}

      {:ok, status, _headers, body} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp keyed(opts), do: Keyword.put(opts, :project_prefix, nil)

  @max_delete 1000

  @doc """
  DeleteObjects, 1,000 keys per request. A request that fails as a whole fails every key
  in it.
  """
  @impl true
  def delete_objects(keys, opts) do
    opts = keyed(opts)

    keys
    |> Enum.chunk_every(@max_delete)
    |> Enum.reduce({[], []}, fn chunk, {deleted, failed} ->
      {d, f} = delete_chunk(chunk, opts)
      {deleted ++ d, failed ++ f}
    end)
  end

  defp delete_chunk(keys, opts) do
    by_object = Map.new(keys, &{bucket_key(&1, opts), &1})

    body =
      IO.iodata_to_binary([
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Quiet>true</Quiet>),
        Enum.map(Map.keys(by_object), &["<Object><Key>", xml_escape(&1), "</Key></Object>"]),
        "</Delete>"
      ])

    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    headers = [{"content-md5", Base.encode64(:crypto.hash(:md5, body))}]

    case request_url(:post, bucket_query_url(opts, "delete"), opts, headers, body, hash, []) do
      {:ok, 200, _headers, response} ->
        refused = delete_errors(response, by_object)
        {Enum.reject(keys, &Map.has_key?(refused, &1)), Map.to_list(refused)}

      {:ok, status, _headers, response} ->
        {[], Enum.map(keys, &{&1, {:http, status, response}})}

      {:error, reason} ->
        {[], Enum.map(keys, &{&1, reason})}
    end
  end

  # In quiet mode the response lists only the keys that could not be deleted.
  defp delete_errors(response, by_object) do
    ~r|<Error>(.*?)</Error>|s
    |> Regex.scan(response, capture: :all_but_first)
    |> Map.new(fn [error] ->
      {Map.get(by_object, xml_unescape(xml_field(error, "Key")), :unknown),
       {:s3, xml_field(error, "Code"), xml_unescape(xml_field(error, "Message"))}}
    end)
  end

  defp xml_field(xml, name) do
    case Regex.run(~r|<#{name}>(.*?)</#{name}>|s, xml, capture: :all_but_first) do
      [value] -> value
      nil -> ""
    end
  end

  @xml_entities [{"&", "&amp;"}, {"<", "&lt;"}, {">", "&gt;"}, {"\"", "&quot;"}, {"'", "&apos;"}]

  defp xml_escape(text),
    do:
      Enum.reduce(@xml_entities, text, fn {char, entity}, acc ->
        String.replace(acc, char, entity)
      end)

  defp xml_unescape(text) do
    @xml_entities
    |> Enum.reverse()
    |> Enum.reduce(text, fn {char, entity}, acc -> String.replace(acc, entity, char) end)
  end

  @doc "Object URL for a digest under the configured bucket, prefixes and addressing style."
  def url(digest, opts), do: bucket_url(opts) <> "/" <> bucket_key(digest, opts)

  # The key inside the bucket: the store's prefix, the project's (when given), the name.
  defp bucket_key(name, opts) do
    case Keyword.get(opts, :project_prefix) do
      nil -> Path.join(Keyword.get(opts, :prefix, "blobs"), name)
      project -> Path.join([Keyword.get(opts, :prefix, "blobs"), project, name])
    end
  end

  defp bucket_url(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    region = Keyword.get(opts, :region, "us-east-1")

    case {Keyword.get(opts, :endpoint), Keyword.get(opts, :path_style, false)} do
      {nil, false} -> "https://#{bucket}.s3.#{region}.amazonaws.com"
      {nil, true} -> "https://s3.#{region}.amazonaws.com/#{bucket}"
      {endpoint, false} -> endpoint |> String.trim_trailing("/") |> host_prefixed(bucket)
      {endpoint, true} -> "#{String.trim_trailing(endpoint, "/")}/#{bucket}"
    end
  end

  # A request on the bucket itself (`?delete`): virtual-host addressing has an empty path.
  defp bucket_query_url(opts, query) do
    case URI.parse(bucket_url(opts)) do
      %URI{path: nil} = uri -> URI.to_string(%{uri | path: "/", query: query})
      uri -> URI.to_string(%{uri | query: query})
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

  @doc "SigV4 `Authorization` header for S3 (see `Conveyor.Aws.SigV4`)."
  @spec sign(atom(), URI.t(), [{String.t(), String.t()}], String.t(), DateTime.t(), keyword()) ::
          String.t()
  def sign(method, %URI{} = uri, headers, payload_hash, now, opts) do
    creds = %{
      access_key_id: Keyword.fetch!(opts, :access_key_id),
      secret_access_key: Keyword.fetch!(opts, :secret_access_key),
      region: Keyword.get(opts, :region, "us-east-1"),
      service: "s3"
    }

    Conveyor.Aws.SigV4.sign(method, uri, headers, payload_hash, now, creds)
  end

  defp amz_date(now), do: Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
end
