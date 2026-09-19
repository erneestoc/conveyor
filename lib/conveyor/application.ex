defmodule Conveyor.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ConveyorWeb.Telemetry,
      Conveyor.Repo,
      {Oban, Application.fetch_env!(:conveyor, Oban)},
      {Task, &Conveyor.Storage.boot/0},
      {DNSCluster, query: Application.get_env(:conveyor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Conveyor.PubSub},
      Conveyor.Projects.ApiKeyCache,
      Conveyor.Limits,
      Conveyor.Ingest.Supervisor,
      # Start a worker by calling: Conveyor.Worker.start_link(arg)
      # {Conveyor.Worker, arg},
      # Start to serve requests, typically the last entry
      ConveyorWeb.Endpoint,
      {GRPC.Server.Supervisor, grpc_server_opts()}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Conveyor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp grpc_server_opts do
    conf = Application.fetch_env!(:conveyor, Conveyor.Grpc)

    [
      endpoint: Conveyor.Grpc.Endpoint,
      port: Keyword.fetch!(conf, :port),
      start_server: Keyword.get(conf, :start_server, true),
      # Bazel can send multi-megabyte NamedSetOfFiles and progress chunks.
      max_body_size: Keyword.get(conf, :max_body_size, 64 * 1024 * 1024)
    ]
  end

  @impl true
  def config_change(changed, _new, removed) do
    ConveyorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
