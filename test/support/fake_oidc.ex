defmodule Conveyor.FakeOidc do
  @moduledoc """
  A minimal OpenID Connect provider for tests: discovery document, authorization endpoint
  (redirects straight back with a code), token endpoint (client_secret_basic, PKCE
  ignored but accepted) issuing RS256 ID tokens, JWKS and userinfo. The claims put into
  the ID token are set per test with `set_claims/1`.
  """
  import Plug.Conn

  @behaviour Plug

  @client_id "conveyor"
  @client_secret "s3cret"

  def client_id, do: @client_id
  def client_secret, do: @client_secret

  @doc "Starts the provider (once per VM; later calls reuse it); returns its issuer URL."
  def start do
    case Process.whereis(__MODULE__) do
      nil -> start_new()
      _pid -> state(:issuer)
    end
  end

  defp start_new do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    port = Conveyor.GrpcCase.free_port()
    issuer = "http://127.0.0.1:#{port}"

    jwk = %{
      "kty" => "RSA",
      "kid" => "test-key",
      "use" => "sig",
      "alg" => "RS256",
      "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
    }

    {:ok, _} =
      Agent.start(
        fn -> %{pem: pem, jwk: jwk, issuer: issuer, codes: %{}, claims: default_claims()} end,
        name: __MODULE__
      )

    # Unlinked: the provider outlives the setup_all process that started it, so every
    # OIDC test module in the run shares one instance.
    {:ok, server} = Bandit.start_link(plug: __MODULE__, port: port, ip: {127, 0, 0, 1})
    Process.unlink(server)
    issuer
  end

  def default_claims,
    do: %{"sub" => "user-1", "email" => "dev@example.com", "name" => "Dev", "groups" => ["eng"]}

  def set_claims(claims),
    do: Agent.update(__MODULE__, &%{&1 | claims: Map.merge(default_claims(), claims)})

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET", path_info: [".well-known", "openid-configuration"]} = conn, _) do
    issuer = state(:issuer)

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/authorize",
      token_endpoint: issuer <> "/token",
      jwks_uri: issuer <> "/jwks",
      userinfo_endpoint: issuer <> "/userinfo",
      response_types_supported: ["code"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      token_endpoint_auth_methods_supported: ["client_secret_basic"],
      code_challenge_methods_supported: ["S256"]
    })
  end

  def call(%{method: "GET", path_info: ["authorize"]} = conn, _) do
    conn = fetch_query_params(conn)

    %{"redirect_uri" => redirect_uri, "state" => state, "client_id" => @client_id} =
      conn.query_params

    code = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Agent.update(__MODULE__, &put_in(&1, [:codes, code], %{nonce: conn.query_params["nonce"]}))

    conn
    |> put_resp_header(
      "location",
      "#{redirect_uri}?code=#{code}&state=#{URI.encode_www_form(state)}"
    )
    |> send_resp(302, "")
  end

  def call(%{method: "POST", path_info: ["token"]} = conn, _) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)
    expected = "Basic " <> Base.encode64("#{@client_id}:#{@client_secret}")

    with [^expected] <- get_req_header(conn, "authorization"),
         %{nonce: nonce} <-
           Agent.get_and_update(
             __MODULE__,
             &{get_in(&1, [:codes, params["code"]]),
              update_in(&1, [:codes], fn c -> Map.delete(c, params["code"]) end)}
           ) do
      now = System.os_time(:second)

      claims =
        state(:claims)
        |> Map.merge(%{
          "iss" => state(:issuer),
          "aud" => @client_id,
          "iat" => now,
          "exp" => now + 300
        })
        |> Map.merge(if(nonce, do: %{"nonce" => nonce}, else: %{}))

      {:ok, id_token} =
        Assent.JWTAdapter.AssentJWT.sign(claims, "RS256", state(:pem),
          private_key_id: "test-key",
          json_library: Jason
        )

      json(conn, %{
        access_token: "at-" <> params["code"],
        token_type: "Bearer",
        expires_in: 300,
        id_token: id_token
      })
    else
      _ -> conn |> put_status(401) |> json(%{error: "invalid_client"})
    end
  end

  def call(%{method: "GET", path_info: ["jwks"]} = conn, _),
    do: json(conn, %{keys: [state(:jwk)]})

  def call(%{method: "GET", path_info: ["userinfo"]} = conn, _), do: json(conn, state(:claims))
  def call(conn, _), do: send_resp(conn, 404, "not found")

  defp state(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))

  defp json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, Jason.encode!(data))
  end
end
