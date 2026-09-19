defmodule Conveyor.Grpc.Acker do
  @moduledoc """
  Sends `PublishBuildToolEventStreamResponse` acks for one stream as the ingest worker
  reports commits. Runs next to the handler process so reading requests and writing acks
  never block each other. Exits once the final sequence number (the
  `component_stream_finished` marker) has been acknowledged.
  """

  alias Google.Devtools.Build.V1, as: V1

  @doc "Starts an acker linked to the caller for the given gRPC stream."
  @spec start(GRPC.Server.Stream.t()) :: pid()
  def start(stream) do
    parent = self()
    spawn_link(fn -> loop(%{stream: stream, parent: parent, final: nil, acked: 0, sent: %{}}) end)
  end

  @doc "Records that an event was received so its ack latency can be measured."
  @spec note(pid(), pos_integer()) :: :ok
  def note(acker, seq) do
    send(acker, {:sent, seq, System.monotonic_time()})
    :ok
  end

  @doc "Tells the acker which sequence number ends the stream."
  @spec final(pid(), pos_integer()) :: :ok
  def final(acker, seq) do
    send(acker, {:final, seq})
    :ok
  end

  @doc """
  Waits until everything up to `last_seq` has been acknowledged (or the final ack went
  out), then returns. Called by the handler after the request stream ends.
  """
  @spec await(pid(), non_neg_integer(), timeout()) :: :ok | {:error, term()}
  def await(acker, last_seq, timeout \\ :infinity) do
    send(acker, {:await, last_seq})

    receive do
      {:acker_done, ^acker} -> :ok
      {:acker_failed, ^acker, reason} -> {:error, reason}
    after
      timeout -> {:error, :ack_timeout}
    end
  end

  defp loop(state) do
    receive do
      {:sent, seq, t0} ->
        loop(%{state | sent: Map.put(state.sent, seq, t0)})

      {:ack, seq} ->
        GRPC.Server.send_reply(state.stream, %V1.PublishBuildToolEventStreamResponse{
          stream_id: stream_id(state.stream),
          sequence_number: seq
        })

        {t0, sent} = Map.pop(state.sent, seq)
        if t0, do: emit_latency(t0)
        state = %{state | acked: max(state.acked, seq), sent: sent}
        if done?(state), do: finish(state), else: loop(state)

      {:ack_failed, _seq, reason} ->
        send(state.parent, {:acker_failed, self(), reason})

      {:final, seq} ->
        state = %{state | final: seq}
        if done?(state), do: finish(state), else: loop(state)

      {:await, last_seq} ->
        state = %{state | final: state.final || last_seq}
        if done?(state), do: finish(state), else: loop(state)
    end
  end

  # Time from receiving an event on the wire to sending its acknowledgement.
  defp emit_latency(t0) do
    latency_us = System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
    :telemetry.execute([:conveyor, :ingest, :ack], %{latency_us: latency_us, count: 1}, %{})
  end

  defp done?(%{final: nil}), do: false
  defp done?(%{final: final, acked: acked}), do: acked >= final

  defp finish(state), do: send(state.parent, {:acker_done, self()})

  # Bazel only checks the sequence number, but echoing the stream id is what the API
  # describes; the handler stores it in the stream's local map.
  defp stream_id(%GRPC.Server.Stream{local: %{stream_id: id}}), do: id
  defp stream_id(_), do: nil
end
