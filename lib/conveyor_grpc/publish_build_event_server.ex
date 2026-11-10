defmodule Conveyor.Grpc.PublishBuildEventServer do
  @moduledoc """
  Implements `google.devtools.build.v1.PublishBuildEvent`, the service Bazel talks to when
  `--bes_backend` is set.

    * `PublishLifecycleEvent` (unary): build enqueued / invocation started / invocation
      finished / build finished, sent around the tool event stream.
    * `PublishBuildToolEventStream` (bidirectional): the ordered Build Event Protocol
      stream. Every `OrderedBuildEvent` is acknowledged, in order, with its
      `sequence_number` — and only after `Conveyor.Ingest.push/2` has committed it. Bazel
      resends from the first un-acked sequence number after any failure.
  """
  use GRPC.Server, service: Google.Devtools.Build.V1.PublishBuildEvent.Service

  alias Conveyor.Bep.Event
  alias Conveyor.Grpc.Acker
  alias Conveyor.Ingest
  alias Conveyor.Limits
  alias Google.Devtools.Build.V1, as: V1

  @spec publish_lifecycle_event(V1.PublishLifecycleEventRequest.t(), GRPC.Server.Stream.t()) ::
          any()
  def publish_lifecycle_event(%V1.PublishLifecycleEventRequest{} = req, stream) do
    ctx = context(stream, req.notification_keywords, req.project_id)

    case Ingest.lifecycle(ctx, req.build_event) do
      :ok ->
        :ok

      {:error, :not_found} ->
        raise not_found(req.build_event)

      {:error, reason} ->
        raise GRPC.RPCError,
          status: :unavailable,
          message: "lifecycle event not accepted: #{inspect(reason)}"
    end

    req
    |> GRPC.Stream.unary(materializer: stream)
    |> GRPC.Stream.map(fn _ -> %Google.Protobuf.Empty{} end)
    |> GRPC.Stream.run()
  end

  @spec publish_build_tool_event_stream(Enumerable.t(), GRPC.Server.Stream.t()) :: any()
  def publish_build_tool_event_stream(requests, stream) do
    # Reading requests and sending acks happen in different processes so that the handler
    # never waits on a commit: events are pushed as they arrive and acknowledged, strictly in
    # order, as the writer commits them. Cowboy accepts replies from any process.
    %{ctx: %{api_key_id: key_id, limits: limits}} = stream.local

    case Limits.acquire_stream(key_id, limits || Limits.defaults()) do
      :ok ->
        try do
          run_stream(requests, stream)
        after
          Limits.release_stream(key_id)
        end

      {:error, :too_many_streams} ->
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "too many concurrent streams for this API key (limit #{limits.max_streams})"
    end
  end

  defp run_stream(requests, stream) do
    # A failed batch ends the RPC from the acker's side (it is linked and exits with an
    # UNAVAILABLE error), wherever this process is: reading, pushing or awaiting.
    acker = Acker.start(stream)

    last_seq =
      Enum.reduce(requests, 0, fn %V1.PublishBuildToolEventStreamRequest{ordered_build_event: obe} =
                                    req,
                                  last ->
        ctx = context(stream, req.notification_keywords, req.project_id)
        # Bazel only checks the sequence number, but echoing the stream id is what the API
        # describes.
        if last == 0, do: Acker.stream_id(acker, obe.stream_id)

        if Event.bes_kind(obe.event) == :component_stream_finished,
          do: Acker.final(acker, obe.sequence_number)

        :ok = Limits.throttle(ctx.api_key_id, ctx.limits || Limits.defaults())
        Acker.note(acker, obe.sequence_number)

        case Ingest.push(ctx, obe, acker) do
          :ok ->
            obe.sequence_number

          {:error, :out_of_order} ->
            # FAILED_PRECONDITION makes Bazel give the upload up, so it must be a real gap:
            # after a failed batch the worker is gone and the next event of this
            # connection lands on a fresh worker, ahead of the row. That is the failure.
            with {:error, reason} <- Acker.check(acker), do: raise(Acker.failure(reason))

            raise GRPC.RPCError,
              status: :failed_precondition,
              message: "unexpected sequence number #{obe.sequence_number}"

          {:error, :not_found} ->
            raise not_found(obe)

          {:error, reason} ->
            raise GRPC.RPCError,
              status: :unavailable,
              message: "event not accepted: #{inspect(reason)}"
        end
      end)

    case Acker.await(acker, last_seq) do
      :ok ->
        :ok

      {:error, reason} ->
        raise Acker.failure(reason)
    end
  end

  # An invocation id that exists under another project. NOT_FOUND, the answer the HTTP
  # upload and the web give for such an id: to this key the build does not exist, and the
  # message names neither the owner nor what the build holds. A refusal of any kind tells a
  # caller the id is taken (a free id would have been accepted), which is all it tells.
  defp not_found(%V1.OrderedBuildEvent{stream_id: %V1.StreamId{invocation_id: id}}) do
    GRPC.RPCError.exception(
      status: :not_found,
      message: "no invocation #{id} in this key's project"
    )
  end

  defp context(%GRPC.Server.Stream{local: %{ctx: ctx}}, keywords, project_id) do
    %{ctx | keywords: keywords || [], instance_name: blank_to_nil(project_id)}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
