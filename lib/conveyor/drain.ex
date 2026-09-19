defmodule Conveyor.Drain do
  @moduledoc """
  Graceful shutdown. When the release receives SIGTERM, `Conveyor.Application.prep_stop/1`
  starts draining: readiness turns 503 (so balancers stop routing here), new BES streams
  are refused with UNAVAILABLE (Bazel retries elsewhere), and shutdown waits for open
  streams to finish, up to `SHUTDOWN_DRAIN_SECONDS`.
  """
  require Logger

  @term {__MODULE__, :draining}

  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@term, false)

  @spec start() :: :ok
  def start, do: :persistent_term.put(@term, true)

  @doc "Cancels draining (tests)."
  @spec stop() :: :ok
  def stop do
    :persistent_term.put(@term, false)
    :ok
  end

  @doc "Starts draining and waits until no BES streams are open or the timeout passes."
  @spec run(non_neg_integer()) :: :ok | :timeout
  def run(timeout_ms) do
    start()

    Logger.info(
      "draining: refusing new streams, waiting up to #{timeout_ms} ms for #{open_streams()} open streams"
    )

    wait(System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait(deadline) do
    cond do
      open_streams() == 0 ->
        Logger.info("drain complete")
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("drain timeout with #{open_streams()} streams still open")
        :timeout

      true ->
        Process.sleep(200)
        wait(deadline)
    end
  end

  defp open_streams do
    Conveyor.Limits.total_streams()
  rescue
    ArgumentError -> 0
  end

  @doc "Configured drain budget in milliseconds."
  def timeout_ms, do: Application.get_env(:conveyor, :shutdown_drain_seconds, 30) * 1000
end
