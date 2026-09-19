defmodule Conveyor.Ingest.Retry do
  @moduledoc """
  Bounded retry with exponential backoff for transient database failures on the ingest
  path (pool exhaustion, dropped connections). Overload must turn into latency, never
  into failed streams: Bazel's own retry budget is only a few seconds.
  """

  require Logger

  @default_delays [50, 200, 800]

  @doc """
  Runs `fun` and retries it on transient errors, sleeping `delays` between attempts.
  Returns the function's result, or re-raises the last error once attempts are exhausted.
  """
  @spec with_backoff((-> term()), keyword()) :: term()
  def with_backoff(fun, opts \\ []) do
    delays = Keyword.get(opts, :delays, @default_delays)
    label = Keyword.get(opts, :label, "operation")
    attempt(fun, delays, label)
  end

  defp attempt(fun, delays, label) do
    fun.()
  rescue
    error ->
      case {transient?(error), delays} do
        {true, [delay | rest]} ->
          Logger.warning(
            "#{label}: transient database error, retrying in #{delay} ms: #{Exception.message(error)}"
          )

          Process.sleep(delay)
          attempt(fun, rest, label)

        _ ->
          reraise error, __STACKTRACE__
      end
  end

  @doc "Whether an error is worth retrying."
  @spec transient?(Exception.t()) :: boolean()
  def transient?(%DBConnection.ConnectionError{}), do: true

  def transient?(%Postgrex.Error{postgres: %{code: code}})
      when code in [
             :serialization_failure,
             :deadlock_detected,
             :too_many_connections,
             :cannot_connect_now,
             :admin_shutdown
           ],
      do: true

  def transient?(_), do: false
end
