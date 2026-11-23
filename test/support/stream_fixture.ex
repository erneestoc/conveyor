defmodule Conveyor.StreamFixture do
  @moduledoc """
  The recorded streams of `test/fixtures/stream` (Bazel with
  `--build_event_publish_all_actions`) and the compact execution logs of the same builds,
  pushed through the real ingest path.
  """
  alias Conveyor.Bep.Replay
  alias Conveyor.Ingest
  alias Google.Devtools.Build.V1, as: V1

  defdelegate path(name, ext), to: Conveyor.Seed.StreamDemo
  defdelegate events(name, opts \\ []), to: Conveyor.Seed.StreamDemo
  defdelegate started_at(name), to: Conveyor.Seed.StreamDemo

  def log(name), do: File.read!(path(name, "log"))

  def stream_id(id), do: %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}

  @doc "The ordered events of a stream for `id`, the end-of-stream marker last."
  def ordered(id, events) do
    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    obes = Enum.with_index(events, fn e, i -> Replay.ordered_event(stream_id(id), i + 1, e) end)
    obes ++ [Replay.ordered_event(stream_id(id), length(events) + 1, marker)]
  end

  @doc "Pushes a whole build the way the gRPC handler does; returns its id."
  def ingest!(ctx, events, id \\ Replay.uuid()) do
    :ok = Ingest.push_all(ctx, ordered(id, events))
    id
  end
end
