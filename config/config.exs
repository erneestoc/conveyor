# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :conveyor,
  ecto_repos: [Conveyor.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
# Ingest pipeline defaults (see Conveyor.Ingest); runtime.exs overrides from env in prod
config :conveyor, Conveyor.Ingest,
  # :api_key requires a valid x-api-key / bearer token on every BES call; :none maps every
  # stream to the "default" project (development and trusted networks only)
  auth: :api_key,
  idle_timeout_ms: 10 * 60 * 1000,
  linger_ms: 30_000,
  batch_max_events: 500,
  batch_max_bytes: 256 * 1024,
  batch_flush_ms: 50,
  writer_shards: System.schedulers_online(),
  writer_flush_ms: 20,
  broadcast_interval_ms: 250

config :conveyor, Oban,
  repo: Conveyor.Repo,
  queues: [default: 10, maintenance: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Conveyor.Workers.PartitionMaintenance},
       {"30 3 * * *", Conveyor.Workers.BlobMaintenance}
     ]}
  ]

# BES gRPC listener (Bazel's --bes_backend target)
config :conveyor, Conveyor.Grpc,
  port: 1985,
  start_server: true,
  # Built-in remote cache sink (ByteStream Write + CAS) so Bazel can upload BEP files here
  cas_sink: false,
  cas_ttl_days: 14

# Artifact fetching (profiles, test logs) from remote caches
config :conveyor, Conveyor.Artifacts, max_bytes: 512 * 1024 * 1024

config :conveyor, ConveyorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ConveyorWeb.ErrorHTML, json: ConveyorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Conveyor.PubSub,
  live_view: [signing_salt: "VHkoRfuA"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  conveyor: [
    args:
      ~w(js/app.js js/profile_worker.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  conveyor: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Per-key ingest limits (see Conveyor.Limits); runtime.exs reads MAX_* in prod
config :conveyor, Conveyor.Limits,
  max_streams_per_key: 200,
  max_events_per_second_per_key: 5_000,
  max_log_bytes: 256 * 1024 * 1024

# Sign-in policy (see Conveyor.Accounts); runtime.exs reads AUTH_MODE, OIDC_*, ADMIN_* in prod
config :conveyor, Conveyor.Accounts,
  mode: :open,
  admin_token: nil,
  admin_emails: [],
  admin_groups: [],
  groups_claim: "groups",
  allowed_email_domains: [],
  oidc: []

# Blob store for profiles, test logs and CAS uploads (see Conveyor.Blobs)
config :conveyor, Conveyor.Blobs, adapter: :disk, dir: "tmp/blobs"
