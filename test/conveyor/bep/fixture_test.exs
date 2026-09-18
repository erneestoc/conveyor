defmodule Conveyor.Bep.FixtureTest do
  use ExUnit.Case, async: true

  alias BuildEventStream.BuildEvent
  alias Conveyor.Bep.{Event, Fixture}

  @fixtures Path.join(File.cwd!(), "test/fixtures/bep")

  test "reads every recorded fixture and finds a started and a finished event" do
    for path <- Path.wildcard(Path.join(@fixtures, "*.bep")) do
      events = Fixture.read!(path)
      kinds = Enum.map(events, &Event.payload_kind/1)
      assert :started in kinds, "#{path} has no started event"
      assert :finished in kinds, "#{path} has no finished event"
      assert %BuildEvent{last_message: true} = List.last(events)
    end
  end

  test "round-trips through the varint-delimited encoding" do
    events = Fixture.read!(Path.join(@fixtures, "test_failure.bep"))

    assert events ==
             events |> Fixture.encode_all() |> IO.iodata_to_binary() |> Fixture.decode_all!()
  end

  test "varints" do
    for n <- [0, 1, 127, 128, 300, 16_383, 16_384, 1_000_000_000] do
      assert {^n, "rest"} = Fixture.decode_varint(Fixture.encode_varint(n) <> "rest")
    end
  end
end
