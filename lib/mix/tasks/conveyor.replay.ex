defmodule Mix.Tasks.Conveyor.Replay do
  @shortdoc "Replays recorded BEP fixtures into a running BES server"
  @moduledoc """
  Replays `bazel --build_event_binary_file` recordings into a Conveyor server as new builds.

      mix conveyor.replay test/fixtures/bep/clean_build_and_test.bep
      mix conveyor.replay FILE [FILE...] [--host localhost] [--port 1985] [--api-key KEY]
                          [--delay-ms 0] [--repeat 1] [--concurrency 1]
                          [--drop-after N] [--verify]

  Every replay gets a fresh invocation id. `--repeat N --concurrency C` makes it a small
  load generator; `--drop-after N` drops each stream after N events and resumes like Bazel
  would; `--verify` runs the persistence oracle (`Conveyor.Ingest.Verify`) against the
  database afterwards, which requires a reachable database configured for this Mix env.
  """
  use Mix.Task

  @switches [
    host: :string,
    port: :integer,
    api_key: :string,
    delay_ms: :integer,
    repeat: :integer,
    concurrency: :integer,
    drop_after: :integer,
    verify: :boolean
  ]

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, switches: @switches)
    if files == [], do: Mix.raise("usage: mix conveyor.replay FILE [FILE...] [options]")

    verify? = Keyword.get(opts, :verify, false)
    start_apps(verify?)

    repeat = Keyword.get(opts, :repeat, 1)
    concurrency = Keyword.get(opts, :concurrency, 1)
    replay_opts = Keyword.take(opts, [:host, :port, :api_key, :delay_ms, :drop_after])
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
        missing = r.sent - length(Enum.uniq(r.acks))
        status = if missing == 0, do: "ok", else: "MISSING #{missing} ACKS"

        Mix.shell().info(
          "#{Path.basename(file)} → #{r.invocation_id} #{r.sent} events, #{r.duration_ms} ms, #{status}"
        )

      {file, {:error, reason}} ->
        Mix.shell().error("#{Path.basename(file)} FAILED: #{inspect(reason)}")
    end)

    ok = Enum.count(results, &match?({_, {:ok, %{}}}, &1))
    Mix.shell().info("#{ok}/#{length(results)} replays succeeded in #{elapsed} ms")

    verified = if verify?, do: verify(results), else: ok
    if ok != length(results) or verified != length(results), do: exit({:shutdown, 1})
  end

  # Verification needs the repo; plain replays only need the gRPC client.
  defp start_apps(true) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    case Conveyor.Repo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_apps(false) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:grpc)
  end

  defp verify(results) do
    # The final component_stream_finished marker is acked but not stored as an event.
    verified =
      Enum.count(results, fn
        {file, {:ok, r}} ->
          case Conveyor.Ingest.Verify.check(r.invocation_id, r.sent - 1) do
            :ok ->
              true

            {:error, problems} ->
              Mix.shell().error(
                "#{Path.basename(file)} → #{r.invocation_id} VERIFY FAILED: #{inspect(problems)}"
              )

              false
          end

        _ ->
          false
      end)

    Mix.shell().info("#{verified}/#{length(results)} invocations verified")
    verified
  end
end
