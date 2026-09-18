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
    metadata = metadata(opts)

    events = rewrite_invocation_id(events, invocation_id)
    started_at = System.monotonic_time(:millisecond)

    with {:ok, channel} <-
           GRPC.Stub.connect("#{host}:#{port}", adapter: GRPC.Client.Adapters.Mint) do
      try do
        stream_id = %V1.StreamId{
          build_id: build_id,
          invocation_id: invocation_id,
          component: :TOOL
        }

        with :ok <-
               maybe_lifecycle(lifecycle?, channel, metadata, project_id, [
                 {%{stream_id | invocation_id: ""}, 1,
                  {:build_enqueued, %V1.BuildEvent.BuildEnqueued{}}},
                 {stream_id, 1,
                  {:invocation_attempt_started,
                   %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}}
               ]),
             {:ok, acks} <- send_stream(channel, metadata, project_id, stream_id, events, delay),
             :ok <-
               maybe_lifecycle(lifecycle?, channel, metadata, project_id, [
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
             duration_ms: System.monotonic_time(:millisecond) - started_at
           }}
        end
      after
        GRPC.Stub.disconnect(channel)
      end
    end
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

  defp send_stream(channel, metadata, project_id, stream_id, events, delay) do
    stream = Stub.publish_build_tool_event_stream(channel, metadata: metadata)

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {event, seq} ->
      if delay > 0, do: Process.sleep(delay)
      GRPC.Stub.send_request(stream, request(project_id, ordered_event(stream_id, seq, event)))
    end)

    finished =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    final = request(project_id, ordered_event(stream_id, length(events) + 1, finished))
    GRPC.Stub.send_request(stream, final, end_stream: true)

    with {:ok, replies} <- GRPC.Stub.recv(stream) do
      Enum.reduce_while(replies, {:ok, []}, fn
        {:ok, %V1.PublishBuildToolEventStreamResponse{sequence_number: seq}}, {:ok, acc} ->
          {:cont, {:ok, [seq | acc]}}

        {:error, reason}, _ ->
          {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, acks} -> {:ok, Enum.reverse(acks)}
        error -> error
      end
    end
  end

  defp request(project_id, obe),
    do: %V1.PublishBuildToolEventStreamRequest{ordered_build_event: obe, project_id: project_id}

  defp maybe_lifecycle(false, _channel, _metadata, _project_id, _events), do: :ok

  defp maybe_lifecycle(true, channel, metadata, project_id, events) do
    Enum.reduce_while(events, :ok, fn {stream_id, seq, payload}, :ok ->
      req = %V1.PublishLifecycleEventRequest{
        build_event: ordered_event(stream_id, seq, payload),
        project_id: project_id
      }

      case Stub.publish_lifecycle_event(channel, req, metadata: metadata) do
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
