defmodule Conveyor.Loadgen.CLI do
  @moduledoc """
  Command line for the load generator (`bes_loadgen` escript / `mix conveyor.loadgen`).

      bes_loadgen --hosts localhost:1985,localhost:1986 --api-key KEY \\
        --fixtures 'test/fixtures/bep/*.bep' --streams 200 --builds 2000 \\
        [--duration-s 300] [--delay-ms 0] [--jitter-ms 100] [--drop-after 20] \\
        [--duplicate-every 10] [--retries 3] [--report out.json] [--verify] [--tls]

  `--tls` dials `grpcs://` with the system CA store (a TLS balancer or Caddy in front).

  Exit status is non-zero when any build failed or any ack went missing.
  """

  @switches [
    hosts: :string,
    api_key: :string,
    fixtures: :string,
    streams: :integer,
    builds: :integer,
    duration_s: :integer,
    delay_ms: :integer,
    jitter_ms: :integer,
    drop_after: :integer,
    duplicate_every: :integer,
    retries: :integer,
    report: :string,
    verify: :boolean,
    tls: :boolean,
    help: :boolean
  ]

  def main(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] -> usage(1)
      opts[:help] -> usage(0)
      true -> run(opts)
    end
  end

  @doc "Parses CLI options into `Conveyor.Loadgen.run/1` options."
  def loadgen_opts(opts) do
    [
      hosts: (opts[:hosts] || "localhost:1985") |> String.split(",", trim: true),
      fixtures: (opts[:fixtures] || "test/fixtures/bep/*.bep") |> String.split(",", trim: true),
      streams: opts[:streams] || 10,
      builds: opts[:builds] || (opts[:streams] || 10) * 5,
      duration_ms: opts[:duration_s] && opts[:duration_s] * 1000,
      delay_ms: opts[:delay_ms] || 0,
      jitter_ms: opts[:jitter_ms] || 0,
      drop_after: opts[:drop_after],
      duplicate_every: opts[:duplicate_every],
      retries: opts[:retries] || 0,
      api_key: opts[:api_key]
    ]
  end

  defp run(opts) do
    {:ok, _} = Application.ensure_all_started(:grpc)
    report = Conveyor.Loadgen.run(loadgen_opts(opts))
    IO.puts(Conveyor.Loadgen.format(report))
    if opts[:report], do: File.write!(opts[:report], Jason.encode!(report, pretty: true))

    verified? = if opts[:verify], do: verify(report), else: true
    if report.builds_failed > 0 or report.missing_acks > 0 or not verified?, do: halt(1)
  end

  # Verification runs the persistence oracle and needs the repo (mix task only).
  defp verify(report) do
    if Code.ensure_loaded?(Conveyor.Ingest.Verify) and Process.whereis(Conveyor.Repo) do
      # The final component_stream_finished marker is acked but not stored as an event.
      failures =
        Enum.reject(report.invocations, fn %{id: id, sent: sent} ->
          match?(:ok, Conveyor.Ingest.Verify.check(id, sent - 1))
        end)

      IO.puts(
        "verified #{length(report.invocations) - length(failures)}/#{length(report.invocations)} invocations"
      )

      Enum.each(failures, &IO.puts("  VERIFY FAILED #{&1.id}"))
      failures == []
    else
      IO.puts("--verify needs a database: run through `mix conveyor.loadgen --verify`")
      false
    end
  end

  defp usage(code) do
    IO.puts(@moduledoc)
    halt(code)
  end

  defp halt(code) do
    if function_exported?(Mix, :env, 0), do: exit({:shutdown, code}), else: System.halt(code)
  end
end
