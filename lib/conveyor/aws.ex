defmodule Conveyor.Aws do
  @moduledoc """
  The little AWS client Conveyor needs, with no extra dependencies: credentials from
  configuration, environment or the EC2 instance role (IMDSv2, cached until shortly before
  expiry), the region, and `DescribeInstances` for cluster discovery.
  """
  alias Conveyor.Aws.SigV4

  @imds_default "http://169.254.169.254"
  @term {__MODULE__, :imds_credentials}

  def config(key, default \\ nil),
    do: Application.get_env(:conveyor, __MODULE__, []) |> Keyword.get(key, default)

  @doc """
  Credentials as a map with `:access_key_id`, `:secret_access_key`, optional
  `:session_token`. Explicit values in `opts` win, then the environment, then IMDS.
  """
  @spec credentials(keyword()) :: {:ok, map()} | {:error, term()}
  def credentials(opts \\ []) do
    explicit = %{
      access_key_id: Keyword.get(opts, :access_key_id) || System.get_env("AWS_ACCESS_KEY_ID"),
      secret_access_key:
        Keyword.get(opts, :secret_access_key) || System.get_env("AWS_SECRET_ACCESS_KEY"),
      session_token: Keyword.get(opts, :session_token) || System.get_env("AWS_SESSION_TOKEN")
    }

    if explicit.access_key_id && explicit.secret_access_key,
      do: {:ok, explicit},
      else: imds_credentials()
  end

  @doc "The region from options, `AWS_REGION`/`AWS_DEFAULT_REGION`, or IMDS."
  @spec region(keyword()) :: String.t() | nil
  def region(opts \\ []) do
    Keyword.get(opts, :region) || System.get_env("AWS_REGION") ||
      System.get_env("AWS_DEFAULT_REGION") ||
      imds_region()
  end

  @doc "Instance role credentials from IMDSv2, cached in a persistent term."
  @spec imds_credentials() :: {:ok, map()} | {:error, term()}
  def imds_credentials do
    case :persistent_term.get(@term, nil) do
      %{expires_at: exp} = creds ->
        if DateTime.compare(exp, DateTime.add(DateTime.utc_now(), 300, :second)) == :gt,
          do: {:ok, creds},
          else: fetch_imds_credentials()

      nil ->
        fetch_imds_credentials()
    end
  end

  defp fetch_imds_credentials do
    with {:ok, token} <- imds_token(),
         {:ok, role} <- imds_get("/latest/meta-data/iam/security-credentials/", token),
         role = role |> String.split("\n", trim: true) |> List.first(),
         {:ok, body} <- imds_get("/latest/meta-data/iam/security-credentials/#{role}", token),
         {:ok, %{"AccessKeyId" => id, "SecretAccessKey" => secret} = doc} <- Jason.decode(body) do
      expires_at =
        case doc["Expiration"] && DateTime.from_iso8601(doc["Expiration"]) do
          {:ok, dt, _} -> dt
          _ -> DateTime.add(DateTime.utc_now(), 3600, :second)
        end

      creds = %{
        access_key_id: id,
        secret_access_key: secret,
        session_token: doc["Token"],
        expires_at: expires_at
      }

      :persistent_term.put(@term, creds)
      {:ok, creds}
    else
      {:error, reason} -> {:error, {:imds, reason}}
      other -> {:error, {:imds, other}}
    end
  end

  defp imds_region do
    with {:ok, token} <- imds_token(),
         {:ok, region} <- imds_get("/latest/meta-data/placement/region", token) do
      String.trim(region)
    else
      _ -> nil
    end
  end

  @doc "The private IPv4 address of this instance, from IMDS."
  @spec imds_private_ip() :: {:ok, String.t()} | {:error, term()}
  def imds_private_ip do
    with {:ok, token} <- imds_token(),
         {:ok, ip} <- imds_get("/latest/meta-data/local-ipv4", token) do
      {:ok, String.trim(ip)}
    end
  end

  defp imds_token do
    url = String.to_charlist(imds_endpoint() <> "/latest/api/token")
    headers = [{~c"x-aws-ec2-metadata-token-ttl-seconds", ~c"300"}]

    case :httpc.request(:put, {url, headers, ~c"text/plain", ""}, http_opts(),
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, token}} -> {:ok, token}
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp imds_get(path, token) do
    url = String.to_charlist(imds_endpoint() <> path)
    headers = [{~c"x-aws-ec2-metadata-token", String.to_charlist(token)}]

    case :httpc.request(:get, {url, headers}, http_opts(), body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp imds_endpoint, do: config(:imds_endpoint, @imds_default)
  defp http_opts, do: [timeout: 2_000, connect_timeout: 1_000]

  @doc "Clears cached IMDS credentials (tests, or after a role change)."
  def reset, do: :persistent_term.erase(@term)

  @doc """
  Private IPs of running instances carrying `tag=value`, via `DescribeInstances`.
  Options: `:region`, `:endpoint` (tests), credentials as for `credentials/1`.
  """
  @spec describe_instances_by_tag(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def describe_instances_by_tag(tag, value, opts \\ []) do
    with region when is_binary(region) <- region(opts) || {:error, :no_region},
         {:ok, creds} <- credentials(opts) do
      endpoint = Keyword.get(opts, :endpoint) || "https://ec2.#{region}.amazonaws.com"
      uri = URI.parse(endpoint)

      body =
        URI.encode_query(%{
          "Action" => "DescribeInstances",
          "Version" => "2016-11-15",
          "Filter.1.Name" => "tag:#{tag}",
          "Filter.1.Value.1" => value,
          "Filter.2.Name" => "instance-state-name",
          "Filter.2.Value.1" => "running"
        })

      now = DateTime.utc_now()
      payload_hash = SigV4.hex_sha256(body)

      headers =
        [
          {"host", host_header(uri)},
          {"content-type", "application/x-www-form-urlencoded; charset=utf-8"},
          {"x-amz-content-sha256", payload_hash},
          {"x-amz-date", SigV4.amz_date(now)}
        ] ++
          if(creds[:session_token], do: [{"x-amz-security-token", creds.session_token}], else: [])

      auth =
        SigV4.sign(
          :post,
          %{uri | path: uri.path || "/"},
          headers,
          payload_hash,
          now,
          Map.merge(creds, %{region: region, service: "ec2"})
        )

      charlist_headers =
        for {k, v} <- [{"authorization", auth} | headers],
            k != "host" and k != "content-type",
            do: {String.to_charlist(k), String.to_charlist(v)}

      url = String.to_charlist(URI.to_string(%{uri | path: uri.path || "/"}))

      case :httpc.request(
             :post,
             {url, charlist_headers, ~c"application/x-www-form-urlencoded; charset=utf-8", body},
             [timeout: 10_000, connect_timeout: 5_000],
             body_format: :binary
           ) do
        {:ok, {{_, 200, _}, _, xml}} -> {:ok, private_ips(xml)}
        {:ok, {{_, status, _}, _, resp}} -> {:error, {:http, status, resp}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port in [nil, 80, 443] and
         ((scheme == "http" and port != 443) or (scheme == "https" and port != 80)),
       do: host,
       else: "#{host}:#{port}"
  end

  @doc false
  # Instance-level privateIpAddress elements (not the ones under networkInterfaceSet).
  def private_ips(xml) do
    handler = fn
      {:startElement, _, name, _, _}, _loc, {stack, _text, acc} ->
        {[List.to_string(name) | stack], nil, acc}

      {:characters, chars}, _loc, {stack, _text, acc} ->
        {stack, List.to_string(chars), acc}

      {:endElement, _, ~c"privateIpAddress", _},
      _loc,
      {["privateIpAddress", "item", "instancesSet" | _] = stack, text, acc}
      when is_binary(text) ->
        {tl(stack), nil, [String.trim(text) | acc]}

      {:endElement, _, _, _}, _loc, {[_ | rest], _text, acc} ->
        {rest, nil, acc}

      _event, _loc, state ->
        state
    end

    case :xmerl_sax_parser.stream(xml,
           event_fun: handler,
           event_state: {[], nil, []},
           external_entities: :none
         ) do
      {:ok, {_, _, ips}, _} -> ips |> Enum.reverse() |> Enum.uniq()
      _ -> []
    end
  end
end
