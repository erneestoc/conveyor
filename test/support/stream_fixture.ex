defmodule Conveyor.StreamFixture do
  @moduledoc """
  The recorded streams of `test/fixtures/stream` (Bazel with
  `--build_event_publish_all_actions`) and the compact execution logs of the same builds,
  pushed through the real ingest path.
  """
  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Google.Devtools.Build.V1, as: V1

  @dir "test/fixtures/stream"

  def path(name, ext), do: Path.join([File.cwd!(), @dir, "#{name}.#{ext}.zst"])

  @doc """
  The events of a recorded stream. `:shift_us` moves the build in time (its start, its
  actions' times, its finish), `:hits_shift_us` its cache hits (the times of the build
  they were served from; by default with the build); `:tags` are what `--build_metadata`
  would have added.
  """
  def events(name, opts \\ []) do
    shift = Keyword.get(opts, :shift_us, 0)
    hits_shift = Keyword.get(opts, :hits_shift_us, shift)
    tags = Keyword.get(opts, :tags, %{})
    events = name |> path("bep") |> Fixture.read!()

    started =
      Enum.find_value(events, fn
        %{payload: {:started, s}} -> s.start_time
        _ -> nil
      end)

    Enum.map(events, fn
      # Bazel always sends this event; `--build_metadata` fills it.
      %{payload: {:build_metadata, m}} = e ->
        %{e | payload: {:build_metadata, %{m | metadata: Map.merge(m.metadata, tags)}}}

      # A cache hit carries the times of the build that filled the cache.
      %{payload: {:action, %{start_time: %{} = at}}} = e
      when {at.seconds, at.nanos} < {started.seconds, started.nanos} ->
        shift(e, hits_shift)

      e ->
        shift(e, shift)
    end)
  end

  @doc "When the recorded build started (`BuildStarted.start_time`)."
  def started_at(name) do
    name
    |> path("bep")
    |> Fixture.read!()
    |> Enum.find_value(fn
      %{payload: {:started, s}} -> Conveyor.Bep.Event.to_datetime(s.start_time)
      _ -> nil
    end)
  end

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

  defp shift(event, 0), do: event

  defp shift(%{payload: {:started, s}} = e, us),
    do: %{e | payload: {:started, %{s | start_time: ts(s.start_time, us)}}}

  defp shift(%{payload: {:finished, f}} = e, us),
    do: %{e | payload: {:finished, %{f | finish_time: ts(f.finish_time, us)}}}

  defp shift(%{payload: {:action, a}} = e, us),
    do: %{
      e
      | payload: {:action, %{a | start_time: ts(a.start_time, us), end_time: ts(a.end_time, us)}}
    }

  defp shift(event, _us), do: event

  defp ts(nil, _us), do: nil

  defp ts(%{seconds: s, nanos: n}, us) do
    total = s * 1_000_000_000 + n + us * 1_000

    %Google.Protobuf.Timestamp{
      seconds: Integer.floor_div(total, 1_000_000_000),
      nanos: Integer.mod(total, 1_000_000_000)
    }
  end
end
