defmodule Mix.Tasks.Conveyor.Bench do
  @shortdoc "Runs the PLAN §24 benchmark: this node serves, a child load generator drives"
  @moduledoc """
  Starts Conveyor in this VM (gRPC listener included), drives `mix conveyor.loadgen` as a
  child OS process against it and samples both sides. See `Conveyor.Bench` for what is
  measured and `bench/run.sh` for the environment that makes runs comparable.

      mix conveyor.bench --label baseline --streams 200 --builds 10000
      mix conveyor.bench --label baseline --profile paced      # 1000 paced streams
      mix conveyor.bench --label x --repeat 3                  # median of three runs

  Options: `--label`, `--profile flatout|paced`, `--streams`, `--builds`, `--delay-ms`,
  `--jitter-ms`, `--duration-s`, `--fixtures`, `--repeat`, `--no-reset`, `--no-verify`,
  `--pg-container NAME`, `--notes TEXT`.
  """
  use Mix.Task

  @switches [
    label: :string,
    profile: :string,
    streams: :integer,
    builds: :integer,
    delay_ms: :integer,
    jitter_ms: :integer,
    duration_s: :integer,
    fixtures: :string,
    repeat: :integer,
    reset: :boolean,
    verify: :boolean,
    pg_container: :string,
    notes: :string
  ]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    Mix.Task.run("app.start")

    label = opts[:label] || "run"
    repeat = opts[:repeat] || 1
    base = Conveyor.Bench.profile_opts(opts[:profile], Keyword.delete(opts, :profile))

    reports =
      for i <- 1..repeat do
        run_label = if repeat > 1, do: "#{label}-#{i}", else: label
        report = Conveyor.Bench.run(Keyword.put(base, :label, run_label))
        Mix.shell().info(Conveyor.Bench.format(report))
        report
      end

    if repeat > 1, do: Mix.shell().info(Conveyor.Bench.summarize_repeats(reports))

    bad = Enum.reject(reports, &Conveyor.Bench.correct?/1)
    if bad != [], do: Mix.raise("#{length(bad)} run(s) failed correctness checks")
  end
end
