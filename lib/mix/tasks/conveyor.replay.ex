defmodule Mix.Tasks.Conveyor.Replay do
  @shortdoc "Replays a recorded BEP fixture into a running BES server"
  @moduledoc """
  Replays `bazel --build_event_binary_file` recordings into a Conveyor server as new builds.

      mix conveyor.replay test/fixtures/bep/clean_build_and_test.bep
      mix conveyor.replay FILE [--host localhost] [--port 1985] [--api-key KEY]
                               [--delay-ms 0] [--repeat 1] [--concurrency 1]

  Every replay gets a fresh invocation id. With `--repeat N --concurrency C` it doubles as a
  small load generator; the full `conveyor_loadgen` tool builds on the same module.
  """
  use Mix.Task

  @switches [
    host: :string,
    port: :integer,
    api_key: :string,
    delay_ms: :integer,
    repeat: :integer,
    concurrency: :integer
  ]

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, switches: @switches)
    if files == [], do: Mix.raise("usage: mix conveyor.replay FILE [FILE...] [options]")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:grpc)

    repeat = Keyword.get(opts, :repeat, 1)
    concurrency = Keyword.get(opts, :concurrency, 1)
    replay_opts = Keyword.take(opts, [:host, :port, :api_key, :delay_ms])
    events_by_file = Map.new(files, &{&1, Conveyor.Bep.Fixture.read!(&1)})

    started = System.monotonic_time(:millisecond)

    results =
      for(_ <- 1..repeat, file <- files, do: file)
      |> Task.async_stream(
        fn file -> {file, Conveyor.Bep.Replay.run(events_by_file[file], replay_opts)} end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    elapsed = System.monotonic_time(:millisecond) - started

    Enum.each(results, fn
      {file, {:ok, r}} ->
        missing = r.sent - length(r.acks)
        status = if missing == 0, do: "ok", else: "MISSING #{missing} ACKS"

        Mix.shell().info(
          "#{Path.basename(file)} → #{r.invocation_id} #{r.sent} events, #{r.duration_ms} ms, #{status}"
        )

      {file, {:error, reason}} ->
        Mix.shell().error("#{Path.basename(file)} FAILED: #{inspect(reason)}")
    end)

    ok = Enum.count(results, &match?({_, {:ok, %{}}}, &1))
    Mix.shell().info("#{ok}/#{length(results)} replays succeeded in #{elapsed} ms")
    if ok != length(results), do: exit({:shutdown, 1})
  end
end
