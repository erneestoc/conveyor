defmodule Conveyor.Aws.SigV4 do
  @moduledoc "AWS Signature Version 4 for any service (S3 blobs, EC2 discovery)."

  @doc """
  `Authorization` header value. `headers` are `{lowercase_name, value}` pairs, all of
  which are signed; `payload_hash` is the hex SHA-256 of the body (or `UNSIGNED-PAYLOAD`).
  """
  @spec sign(
          atom(),
          URI.t(),
          [{String.t(), String.t()}],
          String.t(),
          DateTime.t(),
          map() | keyword()
        ) ::
          String.t()
  def sign(method, %URI{} = uri, headers, payload_hash, now, creds) do
    region = get(creds, :region) || "us-east-1"
    service = get(creds, :service) || "s3"
    access_key = get(creds, :access_key_id)
    secret = get(creds, :secret_access_key)
    date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{date}/#{region}/#{service}/aws4_request"

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
      |> hmac(service)
      |> hmac("aws4_request")

    signature = signing_key |> hmac(string_to_sign) |> Base.encode16(case: :lower)

    "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  @doc "`x-amz-date` value."
  def amz_date(now), do: Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

  @doc "Hex SHA-256."
  def hex_sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp get(creds, key) when is_map(creds), do: Map.get(creds, key)
  defp get(creds, key) when is_list(creds), do: Keyword.get(creds, key)

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
    |> Enum.map_join("&", fn {k, v} -> aws_encode(k) <> "=" <> aws_encode(v) end)
  end

  defp aws_encode(s), do: URI.encode(s, &URI.char_unreserved?/1)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
