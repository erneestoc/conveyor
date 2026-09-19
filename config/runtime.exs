import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/conveyor start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :conveyor, ConveyorWeb.Endpoint, server: true
end

config :conveyor, ConveyorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :conveyor, ConveyorWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/conveyor_web/router\.ex$"E,
        ~r"lib/conveyor_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :conveyor, Conveyor.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "40"),
    queue_target: 1_000,
    queue_interval: 10_000,
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :conveyor, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :conveyor, Conveyor.Grpc,
    port: String.to_integer(System.get_env("GRPC_PORT", "1985")),
    cas_sink: System.get_env("CAS_SINK_ENABLED") in ~w(true 1),
    cas_ttl_days: String.to_integer(System.get_env("CAS_TTL_DAYS", "14"))

  config :conveyor, Conveyor.Artifacts,
    max_bytes: String.to_integer(System.get_env("ARTIFACT_MAX_MB", "512")) * 1024 * 1024

  # Sign-in: AUTH_MODE=open (ADMIN_TOKEN gates Settings) or oidc (OIDC_ISSUER, OIDC_CLIENT_ID,
  # OIDC_CLIENT_SECRET, OIDC_SCOPES, OIDC_GROUPS_CLAIM, OIDC_ADMIN_GROUPS, ADMIN_EMAILS,
  # ALLOWED_EMAIL_DOMAINS).
  auth_mode =
    case System.get_env("AUTH_MODE", "open") do
      "oidc" -> :oidc
      "open" -> :open
      other -> raise "AUTH_MODE must be open or oidc, got #{inspect(other)}"
    end

  if auth_mode == :oidc do
    for var <- ~w(OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET) do
      System.get_env(var) || raise "#{var} is required when AUTH_MODE=oidc"
    end
  end

  config :conveyor, Conveyor.Accounts,
    mode: auth_mode,
    admin_token: System.get_env("ADMIN_TOKEN"),
    admin_emails: Conveyor.Accounts.csv(System.get_env("ADMIN_EMAILS")),
    admin_groups: Conveyor.Accounts.csv(System.get_env("OIDC_ADMIN_GROUPS")),
    groups_claim: System.get_env("OIDC_GROUPS_CLAIM", "groups"),
    allowed_email_domains: Conveyor.Accounts.csv(System.get_env("ALLOWED_EMAIL_DOMAINS")),
    oidc: [
      base_url: System.get_env("OIDC_ISSUER"),
      client_id: System.get_env("OIDC_CLIENT_ID"),
      client_secret: System.get_env("OIDC_CLIENT_SECRET"),
      scopes: System.get_env("OIDC_SCOPES", "openid email profile")
    ]

  # Blob store: BLOB_STORE=disk (default, BLOB_DIR) or s3 (required when clustered).
  case System.get_env("BLOB_STORE", "disk") do
    "s3" ->
      config :conveyor, Conveyor.Blobs,
        adapter: :s3,
        s3: [
          bucket:
            System.get_env("S3_BUCKET") || raise("S3_BUCKET is required when BLOB_STORE=s3"),
          region: System.get_env("S3_REGION") || System.get_env("AWS_REGION") || "us-east-1",
          endpoint: System.get_env("S3_ENDPOINT"),
          path_style: System.get_env("S3_PATH_STYLE") in ~w(true 1),
          prefix: System.get_env("S3_PREFIX", "blobs"),
          access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
          session_token: System.get_env("AWS_SESSION_TOKEN")
        ]

    _ ->
      config :conveyor, Conveyor.Blobs,
        adapter: :disk,
        dir: System.get_env("BLOB_DIR", "/var/lib/conveyor/blobs")
  end

  config :conveyor, ConveyorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :conveyor, ConveyorWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :conveyor, ConveyorWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
