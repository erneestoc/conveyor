defmodule Conveyor.Ingest.NormalizerTest do
  use ExUnit.Case, async: true

  alias BuildEventStream, as: BES
  alias Conveyor.Bep.Fixture
  alias Conveyor.Ingest.{Batch, Normalizer}
  alias Conveyor.Invocations.Invocation

  @fixtures Path.join(File.cwd!(), "test/fixtures/bep")
  @id "11111111-1111-4111-8111-111111111111"

  defp run(fixture, opts \\ []) do
    events = Fixture.read!(Path.join(@fixtures, "#{fixture}.bep"))
    inv = %Invocation{id: @id, project_id: 1, started_at: ~U[2026-09-18 00:00:00Z]}
    state = Normalizer.new(inv, opts)
    batch = Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0)

    {state, batch} =
      events
      |> Enum.with_index(1)
      |> Enum.reduce({state, batch}, fn {event, seq}, {state, batch} ->
        Normalizer.apply(state, event, seq, batch)
      end)

    {Normalizer.finalize(state), batch, events}
  end

  test "clean build and test: counters, metrics, tags and targets" do
    {state, batch, events} =
      run("clean_build_and_test",
        keywords: ["user_keyword=fixture"],
        api_key_tags: %{"ci" => "true"}
      )

    inv = state.inv

    assert inv.status == "succeeded"
    assert inv.exit_code_name == "SUCCESS" and inv.exit_code == 0
    assert inv.command == "test" and inv.bazel_version == "9.2.0"
    assert inv.user_name == "ernesto" and is_binary(inv.host)

    assert inv.patterns == [
             "//app:pass_test",
             "//app:sharded_test",
             "//app:uses_greeting_test",
             "//lib:all"
           ]

    assert inv.event_count == length(events)
    assert inv.targets_configured == 5 and inv.targets_completed == 5 and inv.targets_failed == 0
    assert inv.tests_total == 3 and inv.tests_passed == 3
    assert inv.actions_executed > 0 and is_integer(inv.actions_created)

    assert is_integer(inv.wall_ms) and is_integer(inv.critical_path_ms) and
             is_integer(inv.peak_heap_bytes)

    assert inv.stream_finished and inv.finished_at != nil and inv.duration_ms > 0
    assert inv.tags["scenario"] == "clean_build_and_test"
    assert inv.tags["ci"] == "false", "build_metadata beats api key defaults"
    assert inv.tags["keyword"] == "fixture"
    assert inv.tags["command"] == "test"
    assert map_size(inv.configurations) >= 1
    assert Map.has_key?(inv.options, "unstructured") and Map.has_key?(inv.options, "parsed")
    assert inv.log_lines > 0 and inv.log_bytes > 0

    assert map_size(batch.targets) == 5
    assert Enum.all?(Map.values(batch.targets), &(&1.status == "success"))
    assert map_size(batch.tests) == 5, "pass + 3 shards + uses_greeting"
    assert batch.named_sets != []
    assert batch.metrics.build_metrics["actionSummary"]["actionsExecuted"] != nil
    assert Map.has_key?(batch.metrics.tool_logs, "command.profile.gz")
    assert inv.profile_uri =~ ~r/command.*\.profile\.gz$/ and inv.profile_status == "referenced"
  end

  test "test failure and flaky fixtures" do
    {state, _batch, _} = run("test_failure")
    assert state.inv.status == "failed" and state.inv.exit_code_name == "TESTS_FAILED"

    assert state.inv.tests_total == 2 and state.inv.tests_failed == 1 and
             state.inv.tests_passed == 1

    {state, batch, _} = run("flaky_test")
    assert state.inv.status == "succeeded" and state.inv.tests_flaky == 1

    assert Map.has_key?(
             batch.tests,
             {"//app:flaky_test", batch.tests |> Map.keys() |> hd() |> elem(1), 1, 1, 2}
           )
  end

  test "build failure records failed targets and actions" do
    {state, batch, _} = run("build_failure")
    assert state.inv.status == "failed" and state.inv.targets_failed == 1
    assert state.inv.actions_failed == 1
    failed = Enum.find(batch.actions, &(not &1.success))

    assert failed.mnemonic == "Genrule" and failed.exit_code == 1 and
             failed.label == "//lib:broken"

    assert Enum.any?(
             Map.values(batch.targets),
             &(&1.status == "failed" and is_binary(&1.failure_message))
           )
  end

  test "analysis failure is a failed build with no targets" do
    {state, _batch, _} = run("analysis_failure")
    assert state.inv.status == "failed" and state.inv.targets_configured == 0
  end

  test "an aborted stream without a finished event is aborted; nothing at all is unknown" do
    started = %BES.BuildEvent{
      id: %BES.BuildEventId{id: {:started, %BES.BuildEventId.BuildStartedId{}}},
      payload: {:started, %BES.BuildStarted{command: "build"}}
    }

    aborted = %BES.BuildEvent{
      id: %BES.BuildEventId{id: {:build_finished, %BES.BuildEventId.BuildFinishedId{}}},
      payload: {:aborted, %BES.Aborted{reason: :USER_INTERRUPTED, description: "ctrl-c"}}
    }

    aborted2 = %{
      aborted
      | payload: {:aborted, %BES.Aborted{reason: :INTERNAL, description: "cascade"}}
    }

    state = Normalizer.new(%Invocation{id: @id, project_id: 1})
    batch = Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0)

    {state, batch} = Normalizer.apply(state, started, 1, batch)
    {state, batch} = Normalizer.apply(state, aborted, 2, batch)
    {state, _batch} = Normalizer.apply(state, aborted2, 3, batch)
    final = Normalizer.finalize(state, now: ~U[2026-09-18 00:00:10Z])

    assert final.inv.status == "aborted" and final.inv.abort_reason == "USER_INTERRUPTED" and
             final.inv.abort_description == "ctrl-c"

    unknown =
      Normalizer.finalize(
        Normalizer.new(%Invocation{id: @id, started_at: ~U[2026-09-18 00:00:00Z]}),
        now: ~U[2026-09-18 00:00:10Z]
      )

    assert unknown.inv.status == "unknown" and unknown.inv.duration_ms == 10_000
  end

  test "disconnect only affects in-progress invocations" do
    state =
      Normalizer.new(%Invocation{id: @id, status: "in_progress", started_at: DateTime.utc_now()})

    assert Normalizer.disconnect(state).inv.status == "disconnected"
    done = Normalizer.new(%Invocation{id: @id, status: "succeeded"})
    assert Normalizer.disconnect(done) == done
  end

  test "dirty tracking and unknown payloads" do
    state = Normalizer.new(%{id: @id, status: "in_progress"})
    assert Normalizer.set(state, %{}) == state
    state = Normalizer.set(state, %{command: "build"})
    {changes, state} = Normalizer.take_dirty(state)
    assert changes == %{command: "build"} and state.dirty == MapSet.new()

    event = %BES.BuildEvent{payload: {:fetch, %BES.Fetch{success: true}}}

    {state2, batch} =
      Normalizer.apply(state, event, 1, Batch.new(@id, 1, ~D[2026-09-18], 1, 0, 0))

    assert state2.inv.event_count == 1 and Batch.empty?(batch)
  end

  test "file maps cover every oneof" do
    assert Normalizer.file_map(nil) == nil

    assert Normalizer.file_map(%BES.File{name: "a", file: {:uri, "file:///a"}})["uri"] ==
             "file:///a"

    assert Normalizer.file_map(%BES.File{name: "a", file: {:contents, "text"}})["contents"] ==
             "text"

    assert Normalizer.file_map(%BES.File{name: "a", file: {:contents, <<0xFF>>}})["contents"] ==
             Base.encode64(<<0xFF>>)

    assert Normalizer.file_map(%BES.File{name: "a", file: {:symlink_target_path, "/x"}})[
             "symlink_target_path"
           ] == "/x"

    assert Normalizer.file_map(%BES.File{name: "a"}) == %{
             "name" => "a",
             "path_prefix" => [],
             "digest" => nil,
             "length" => 0
           }
  end
end
