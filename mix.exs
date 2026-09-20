defmodule Conveyor.MixProject do
  use Mix.Project

  def project do
    [
      app: :conveyor,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      # `mix escript.build` produces ./bes_loadgen, a standalone load generator (M7).
      escript: [main_module: Conveyor.Loadgen.CLI, name: "bes_loadgen", app: nil],
      releases: [
        conveyor: [include_executables_for: [:unix], applications: [runtime_tools: :permanent]]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Conveyor.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl, :xmerl]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      # Multi-node (M7): cluster formation for Kubernetes, DNS and EC2 auto-scaling groups
      {:libcluster, "~> 3.5"},
      {:bandit, "~> 1.5"},
      # gRPC (BES ingest) and protobuf
      {:grpc_server, "~> 1.0"},
      {:grpc, "~> 1.0"},
      {:protobuf, "~> 0.17.0"},
      # HTTP/2 client adapter for the gRPC client (replay tool, artifact fetching)
      {:mint, "~> 1.9"},
      # Background jobs (retention, partition maintenance, post-processing); exactly-once across nodes
      {:oban, "~> 2.24"},
      # OIDC login (M6)
      {:assent, "~> 0.3.1"},
      # Test coverage gate (95% minimum, see coveralls.json)
      {:stream_data, "~> 1.1", only: [:test]},
      {:excoveralls, "~> 0.18", only: :test},
      # Security tooling (M6): static analysis and dependency advisories, run by mix precommit
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind conveyor", "esbuild conveyor"],
      "assets.deploy": [
        "tailwind conveyor --minify",
        "esbuild conveyor --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "sobelow --exit",
        "deps.audit",
        "cmd node --test assets/test/*.test.mjs",
        "coveralls"
      ]
    ]
  end
end
