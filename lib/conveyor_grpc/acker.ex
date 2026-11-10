defmodule Conveyor.Grpc.Acker do
  @moduledoc """
  Sends `PublishBuildToolEventStreamResponse` acks for one stream as the ingest worker
  reports commits. Runs next to the handler process so reading requests and writing acks
  never block each other. Exits once the final sequence number (the
  `component_stream_finished` marker) has been acknowledged.

  A failed batch (`{:ack_failed, seq, reason}` from the worker) ends the RPC at once: the
  acker tells its parent and exits with the reason the gRPC adapter turns into an
  UNAVAILABLE status. It is linked to the handler, which may be blocked reading the next
  request and would otherwise keep pushing the rest of the connection's events at a worker
  that is gone (each one starting a fresh worker whose acks nobody reads). Bazel retries
  UNAVAILABLE and resends from its last acknowledgement.
  """

  alias Google.Devtools.Build.V1, as: V1

  @doc "Starts an acker linked to the caller for the given gRPC stream."
  @spec start(GRPC.Server.Stream.t()) :: pid()
  def start(stream) do
    parent = self()

    spawn_link(fn ->
      loop(%{stream: stream, stream_id: nil, parent: parent, final: nil, acked: 0, sent: %{}})
    end)
  end

  @doc "Tells the acker the stream id to echo in acknowledgements (known from the first event)."
  @spec stream_id(pid(), V1.StreamId.t() | nil) :: :ok
  def stream_id(acker, stream_id) do
    send(acker, {:stream_id, stream_id})
    :ok
  end

  @doc """
  Whether the acker has seen a failed batch among everything sent to it so far. The handler
  asks before it reports a sequence gap: a gap right after a failed batch is the fresh
  worker of a stream that already failed, and must be answered as the failure it is.
  """
  @spec check(pid(), timeout()) :: :ok | {:error, term()}
  def check(acker, timeout \\ 5_000) do
    ref = Process.monitor(acker)
    send(acker, {:check, self(), ref})

    receive do
      {:acker_ok, ^ref} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:acker_failed, ^acker, reason} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^acker, reason} ->
        {:error, reason}
    after
      timeout -> {:error, :ack_timeout}
    end
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
          stream_id: state.stream_id,
          sequence_number: seq
        })

        {t0, sent} = Map.pop(state.sent, seq)
        if t0, do: emit_latency(t0)
        state = %{state | acked: max(state.acked, seq), sent: sent}
        if done?(state), do: finish(state), else: loop(state)

      {:ack_failed, _seq, reason} ->
        send(state.parent, {:acker_failed, self(), reason})
        # The shape `GRPC.Server.Adapters.Cowboy.Handler` reports as an RPC error when the
        # handler process exits with it (what a raised `GRPC.RPCError` becomes).
        exit({:shutdown, {failure(reason), []}})

      {:stream_id, stream_id} ->
        loop(%{state | stream_id: stream_id})

      {:check, from, ref} ->
        send(from, {:acker_ok, ref})
        loop(state)

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

  @doc "The status a stream ends with when a batch was not persisted."
  @spec failure(term()) :: GRPC.RPCError.t()
  def failure(reason) do
    GRPC.RPCError.exception(
      status: :unavailable,
      message: "event not persisted: #{inspect(reason)}"
    )
  end
end
