defmodule Conveyor.Grpc.PublishBuildEventServer do
  @moduledoc """
  Implements `google.devtools.build.v1.PublishBuildEvent`, the service Bazel talks to when
  `--bes_backend` is set.

  Two RPCs:

    * `PublishLifecycleEvent` (unary): build enqueued / invocation started / invocation
      finished / build finished, sent around the tool event stream.
    * `PublishBuildToolEventStream` (bidirectional): the ordered stream of Build Event
      Protocol events. Every `OrderedBuildEvent` must be acknowledged, in order, with its
      `sequence_number`. Bazel resends from the first un-acked sequence number after any
      failure, so the handler only acks once the event is safely handled.
  """
  use GRPC.Server, service: Google.Devtools.Build.V1.PublishBuildEvent.Service

  require Logger

  alias Conveyor.Bep.Event
  alias Google.Devtools.Build.V1, as: V1

  @spec publish_lifecycle_event(V1.PublishLifecycleEventRequest.t(), GRPC.Server.Stream.t()) ::
          Google.Protobuf.Empty.t()
  def publish_lifecycle_event(%V1.PublishLifecycleEventRequest{} = req, stream) do
    %V1.OrderedBuildEvent{stream_id: stream_id, sequence_number: seq, event: event} =
      req.build_event

    Logger.info(
      "BES lifecycle #{Event.bes_kind(event)} build=#{stream_id && stream_id.build_id} " <>
        "invocation=#{stream_id && stream_id.invocation_id} seq=#{seq}"
    )

    req
    |> GRPC.Stream.unary(materializer: stream)
    |> GRPC.Stream.map(fn _ -> %Google.Protobuf.Empty{} end)
    |> GRPC.Stream.run()
  end

  @spec publish_build_tool_event_stream(Enumerable.t(), GRPC.Server.Stream.t()) :: any()
  def publish_build_tool_event_stream(requests, stream) do
    headers = GRPC.Stream.get_headers(stream)

    Logger.debug(
      "BES stream opened, headers=#{inspect(Map.drop(headers, ["x-api-key", "authorization"]))}"
    )

    # Imperative loop on purpose: acks must go out strictly in sequence order, and the
    # Flow-based GRPC.Stream API may process elements concurrently.
    Enum.each(requests, fn %V1.PublishBuildToolEventStreamRequest{ordered_build_event: obe} ->
      handle_event(obe)

      GRPC.Server.send_reply(stream, %V1.PublishBuildToolEventStreamResponse{
        stream_id: obe.stream_id,
        sequence_number: obe.sequence_number
      })
    end)
  end

  defp handle_event(%V1.OrderedBuildEvent{stream_id: sid, sequence_number: seq, event: event}) do
    case Event.bes_kind(event) do
      :bazel_event ->
        case Event.unwrap(event) do
          {:ok, bep} ->
            Logger.info(
              "BEP #{sid.invocation_id} ##{seq} #{Event.payload_kind(bep)} last=#{bep.last_message}"
            )

          {:error, reason} ->
            Logger.warning("BEP #{sid.invocation_id} ##{seq} undecodable: #{inspect(reason)}")
        end

      kind ->
        Logger.info("BES #{sid.invocation_id} ##{seq} #{kind}")
    end
  end
end
