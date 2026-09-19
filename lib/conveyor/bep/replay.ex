defmodule Conveyor.Bep.Replay do
  @moduledoc """
  Replays a recorded BEP fixture into a BES server exactly the way Bazel would:
  lifecycle events around a `PublishBuildToolEventStream` of `OrderedBuildEvent`s,
  each wrapped in a `google.protobuf.Any`, with a fresh invocation id so every replay is a
  new build. Used by tests, `mix conveyor.replay`, and the load generator.
  """

  alias BuildEventStream.BuildEvent, as: BepEvent
  alias Conveyor.Bep.Fixture
  alias Google.Devtools.Build.V1, as: V1
  alias Google.Devtools.Build.V1.PublishBuildEvent.Stub

  @bep_type_url "type.googleapis.com/build_event_stream.BuildEvent"

  @type result :: %{
          invocation_id: String.t(),
          build_id: String.t(),
          sent: non_neg_integer(),
          acks: [non_neg_integer()],
          duration_ms: non_neg_integer()
        }

  @doc """
  Replays the events in `path` (or a list of decoded events) to `host:port`.

  Options:
    * `:host`, `:port` — BES server (default `localhost:1985`)
    * `:api_key` — sent as the `x-api-key` header
    * `:invocation_id`, `:build_id` — default to fresh UUIDs
    * `:delay_ms` — pause between events (default 0)
    * `:lifecycle` — send lifecycle events (default true)
    * `:project_id` — value of `--bes_instance_name` (default "")
    * `:drop_after` — simulate a connection loss: cancel the stream after this many events
      have been sent, then reconnect and resume from the last acknowledged sequence number,
      exactly like Bazel's retry (the last acked event may be re-sent as a duplicate)
  """
  @spec run(Path.t() | [BepEvent.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(path_or_events, opts \\ [])

  def run(path, opts) when is_binary(path), do: run(Fixture.read!(path), opts)

  def run(events, opts) when is_list(events) do
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 1985)
    invocation_id = Keyword.get_lazy(opts, :invocation_id, &uuid/0)
    build_id = Keyword.get_lazy(opts, :build_id, &uuid/0)
    delay = Keyword.get(opts, :delay_ms, 0)
    lifecycle? = Keyword.get(opts, :lifecycle, true)
    project_id = Keyword.get(opts, :project_id, "")
    drop_after = Keyword.get(opts, :drop_after)
    duplicate_every = Keyword.get(opts, :duplicate_every)
    metadata = metadata(opts)

    events = rewrite_invocation_id(events, invocation_id)
    started_at = System.monotonic_time(:millisecond)

    with {:ok, channel} <-
           GRPC.Stub.connect("#{host}:#{port}", adapter: GRPC.Client.Adapters.Mint) do
      try do
        run_connected(
          channel,
          events,
          invocation_id,
          build_id,
          delay,
          lifecycle?,
          project_id,
          drop_after,
          metadata,
          started_at,
          duplicate_every
        )
      catch
        # A stream the server closed early (e.g. UNAUTHENTICATED) makes later sends exit.
        :exit, reason -> {:error, {:stream_closed, reason}}
      after
        GRPC.Stub.disconnect(channel)
      end
    end
  end

  defp run_connected(
         channel,
         events,
         invocation_id,
         build_id,
         delay,
         lifecycle?,
         project_id,
         drop_after,
         metadata,
         started_at,
         duplicate_every
       ) do
    {:ok, :placeholder}
    |> then(fn _ ->
      stream_id = %V1.StreamId{build_id: build_id, invocation_id: invocation_id, component: :TOOL}

      conn = %{
        channel: channel,
        metadata: metadata,
        project_id: project_id,
        stream_id: stream_id,
        delay: delay,
        duplicate_every: duplicate_every
      }

      with :ok <-
             maybe_lifecycle(lifecycle?, conn, [
               {%{stream_id | invocation_id: ""}, 1,
                {:build_enqueued, %V1.BuildEvent.BuildEnqueued{}}},
               {stream_id, 1,
                {:invocation_attempt_started,
                 %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}}
             ]),
           {:ok, {acks, latencies}} <- send_with_retry(conn, events, drop_after),
           :ok <-
             maybe_lifecycle(lifecycle?, conn, [
               {stream_id, 2,
                {:invocation_attempt_finished,
                 %V1.BuildEvent.InvocationAttemptFinished{invocation_status: status(events)}}},
               {%{stream_id | invocation_id: ""}, 2,
                {:build_finished, %V1.BuildEvent.BuildFinished{status: status(events)}}}
             ]) do
        {:ok,
         %{
           invocation_id: invocation_id,
           build_id: build_id,
           sent: length(events) + 1,
           acks: acks,
           latencies_ms: latencies,
           duration_ms: System.monotonic_time(:millisecond) - started_at
         }}
      end
    end)
  end

  @doc "Wraps a BEP event as Bazel does on the wire."
  @spec ordered_event(V1.StreamId.t(), pos_integer(), BepEvent.t() | {atom(), struct()}) ::
          V1.OrderedBuildEvent.t()
  def ordered_event(stream_id, seq, %BepEvent{} = event) do
    any = %Google.Protobuf.Any{type_url: @bep_type_url, value: BepEvent.encode(event)}
    ordered_event(stream_id, seq, {:bazel_event, any})
  end

  def ordered_event(stream_id, seq, {kind, payload}) do
    %V1.OrderedBuildEvent{
      stream_id: stream_id,
      sequence_number: seq,
      event: %V1.BuildEvent{event_time: now(), event: {kind, payload}}
    }
  end

  defp send_with_retry(conn, events, nil), do: send_stream(conn, events, 1, nil)

  defp send_with_retry(conn, events, drop_after) do
    # First attempt: send `drop_after` events, then drop the connection mid-stream without
    # reading acks (a client that lost its connection cannot know what was acked). Resend
    # everything: the server acknowledges already-committed sequence numbers immediately,
    # which exercises the same deduplication path Bazel relies on after a retry.
    :ok = send_stream(conn, events, 1, drop_after)
    send_stream(conn, events, 1, nil)
  end

  # Sends events `from_seq..N` plus the stream-finished marker as N+1. With `drop_after`,
  # cancels the stream after that many events instead and returns the acks received so far.
  defp send_stream(conn, events, from_seq, drop_after) do
    stream = Stub.publish_build_tool_event_stream(conn.channel, metadata: conn.metadata)
    total = length(events)

    to_send =
      events
      |> Enum.with_index(1)
      |> Enum.drop(from_seq - 1)
      |> then(&if(drop_after, do: Enum.take(&1, drop_after), else: &1))

    sent_at =
      Enum.reduce(to_send, %{}, fn {event, seq}, sent_at ->
        if conn.delay > 0, do: Process.sleep(conn.delay)
        req = request(conn.project_id, ordered_event(conn.stream_id, seq, event))
        GRPC.Stub.send_request(stream, req)

        # Bazel resends an event it believes unacknowledged; the server must ack duplicates
        # without storing them twice.
        if conn.duplicate_every && rem(seq, conn.duplicate_every) == 0,
          do: GRPC.Stub.send_request(stream, req)

        Map.put_new(sent_at, seq, System.monotonic_time(:microsecond))
      end)

    if drop_after do
      GRPC.Stub.cancel(stream)
      :ok
    else
      finished =
        {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

      final = request(conn.project_id, ordered_event(conn.stream_id, total + 1, finished))
      GRPC.Stub.send_request(stream, final, end_stream: true)
      sent_at = Map.put(sent_at, total + 1, System.monotonic_time(:microsecond))

      with {:ok, replies} <- GRPC.Stub.recv(stream) do
        collect_acks(replies, sent_at)
      end
    end
  end

  # Returns the acked sequence numbers in order and the client-observed latency of each
  # first ack (send → ack, milliseconds).
  defp collect_acks(replies, sent_at) do
    Enum.reduce_while(replies, {:ok, [], []}, fn
      {:ok, %V1.PublishBuildToolEventStreamResponse{sequence_number: seq}}, {:ok, acks, lat} ->
        now = System.monotonic_time(:microsecond)

        lat =
          case Map.get(sent_at, seq) do
            nil -> lat
            t0 -> [(now - t0) / 1000 | lat]
          end

        {:cont, {:ok, [seq | acks], lat}}

      {:error, reason}, _ ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, acks, lat} -> {:ok, {Enum.reverse(acks), Enum.reverse(lat)}}
      error -> error
    end
  end

  defp request(project_id, obe),
    do: %V1.PublishBuildToolEventStreamRequest{ordered_build_event: obe, project_id: project_id}

  defp maybe_lifecycle(false, _conn, _events), do: :ok

  defp maybe_lifecycle(true, conn, events) do
    Enum.reduce_while(events, :ok, fn {stream_id, seq, payload}, :ok ->
      req = %V1.PublishLifecycleEventRequest{
        build_event: ordered_event(stream_id, seq, payload),
        project_id: conn.project_id
      }

      case Stub.publish_lifecycle_event(conn.channel, req, metadata: conn.metadata) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:lifecycle, reason}}}
      end
    end)
  end

  defp status(events) do
    result =
      case Enum.find(events, &match?(%BepEvent{payload: {:finished, _}}, &1)) do
        %BepEvent{payload: {:finished, %{exit_code: %{code: 0}}}} -> :COMMAND_SUCCEEDED
        %BepEvent{payload: {:finished, _}} -> :COMMAND_FAILED
        nil -> :UNKNOWN_STATUS
      end

    %V1.BuildStatus{result: result}
  end

  defp metadata(opts) do
    case Keyword.get(opts, :api_key) do
      nil -> %{}
      key -> %{"x-api-key" => key}
    end
  end

  # Bazel puts the invocation id in the Started payload; keep the fixture consistent with
  # the stream id so each replay looks like a distinct build.
  defp rewrite_invocation_id(events, invocation_id) do
    Enum.map(events, fn
      %BepEvent{payload: {:started, started}} = ev ->
        %{ev | payload: {:started, %{started | uuid: invocation_id}}}

      ev ->
        ev
    end)
  end

  defp now do
    us = System.os_time(:microsecond)
    %Google.Protobuf.Timestamp{seconds: div(us, 1_000_000), nanos: rem(us, 1_000_000) * 1_000}
  end

  @doc false
  def uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
