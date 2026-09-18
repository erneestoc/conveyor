import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :conveyor, Conveyor.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5440,
  database: "conveyor_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :conveyor, ConveyorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aNI0aOveqKtohI7Fie9Zfd8r0EU02PC6cMekgQB3RNBbndYHGWGmUj/fFzWUW+aB",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests start the gRPC server on demand with a random port.
config :conveyor, Conveyor.Grpc, port: 0, start_server: false
