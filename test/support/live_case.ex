defmodule ConveyorWeb.LiveCase do
  @moduledoc """
  ConnCase plus a persisted invocation replayed through the normalizer (no gRPC), so
  LiveView tests have realistic rows to render.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use ConveyorWeb.ConnCase
      import Phoenix.LiveViewTest
      import ConveyorWeb.LiveCase
    end
  end

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Ingest
  alias Google.Devtools.Build.V1, as: V1

  @doc """
  Ingests a fixture through the real worker/writer pipeline and waits for it to finish.
  Returns the invocation id.
  """
  def ingest_fixture!(name, ctx) do
    id = Replay.uuid()
    stream_id = %V1.StreamId{build_id: "b", invocation_id: id, component: :TOOL}
    events = Fixture.read!(Path.join([File.cwd!(), "test/fixtures/bep", "#{name}.bep"]))

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {event, seq} ->
      :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id, seq, event))
    end)

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    :ok = Ingest.push_sync(ctx, Replay.ordered_event(stream_id, length(events) + 1, marker))
    :ok = Conveyor.IngestCase.await_worker_exit(id)
    id
  end

  def context do
    project = Conveyor.Projects.ensure_default_project!()
    %Ingest.Context{project_id: project.id, project_slug: project.slug}
  end
end
