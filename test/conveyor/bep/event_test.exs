defmodule Conveyor.Bep.EventTest do
  use ExUnit.Case, async: true

  alias BuildEventStream.BuildEvent, as: BepEvent
  alias Conveyor.Bep.{Event, Fixture, Replay}
  alias Google.Devtools.Build.V1, as: V1

  @fixture Path.join(File.cwd!(), "test/fixtures/bep/test_failure.bep")
  @stream_id %V1.StreamId{build_id: "b", invocation_id: "i", component: :TOOL}

  test "unwraps bazel events packed as Any and names their kinds" do
    [started | _] = Fixture.read!(@fixture)
    %V1.OrderedBuildEvent{event: bes_event} = Replay.ordered_event(@stream_id, 1, started)

    assert Event.bes_kind(bes_event) == :bazel_event
    assert {:ok, ^started} = Event.unwrap(bes_event)
    assert Event.payload_kind(started) == :started
    assert Event.id_kind(started) == :started
  end

  test "lifecycle and control events carry no bazel event" do
    finished =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    %V1.OrderedBuildEvent{event: bes_event} = Replay.ordered_event(@stream_id, 9, finished)

    assert Event.bes_kind(bes_event) == :component_stream_finished
    assert Event.unwrap(bes_event) == :none
    assert Event.bes_kind(%V1.BuildEvent{}) == :unknown
  end

  test "rejects unexpected type urls and undecodable payloads" do
    other = %Google.Protobuf.Any{type_url: "type.googleapis.com/something.Else", value: ""}

    assert {:error, {:unexpected_type_url, _}} =
             Event.unwrap(%V1.BuildEvent{event: {:bazel_event, other}})

    garbage = %Google.Protobuf.Any{
      type_url: "type.googleapis.com/build_event_stream.BuildEvent",
      value: <<0xFF, 0xFF>>
    }

    assert {:error, _} = Event.unwrap(%V1.BuildEvent{event: {:bazel_event, garbage}})
  end

  test "unknown payloads and ids" do
    assert Event.payload_kind(%BepEvent{}) == :unknown
    assert Event.id_kind(%BepEvent{}) == :unknown
  end

  test "time conversions" do
    assert Event.to_datetime(nil) == nil
    assert Event.to_ms(nil) == nil

    assert Event.to_datetime(%Google.Protobuf.Timestamp{seconds: 1_700_000_000, nanos: 5_000}) ==
             ~U[2023-11-14 22:13:20.000005Z]

    assert Event.to_ms(%Google.Protobuf.Duration{seconds: 3, nanos: 250_000_000}) == 3_250
  end
end
