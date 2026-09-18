defmodule Conveyor.Ingest.StatusTest do
  use ExUnit.Case, async: true

  alias Conveyor.Ingest.Status

  test "exit codes map to statuses" do
    assert Status.from_exit_code("SUCCESS", 0) == "succeeded"
    assert Status.from_exit_code("INTERRUPTED", 8) == "aborted"
    assert Status.from_exit_code(nil, 8) == "aborted"
    assert Status.from_exit_code("BUILD_FAILURE", 1) == "failed"
    assert Status.from_exit_code("TESTS_FAILED", 3) == "failed"
  end

  test "categories" do
    assert Status.category(nil) == nil
    assert Status.category("SUCCESS") == "success"
    assert Status.category("TESTS_FAILED") == "tests failed"
    assert Status.category("BUILD_FAILURE") == "build failed"
    assert Status.category("OOM_ERROR") == "out of memory"
    assert Status.category("SOME_NEW_CODE") == "some new code"

    for name <-
          ~w(NO_TESTS_FOUND PARSING_FAILURE ANALYSIS_FAILURE PARTIAL_ANALYSIS_FAILURE COMMAND_LINE_ERROR INTERRUPTED REMOTE_ERROR REMOTE_ENVIRONMENTAL_ERROR LOCAL_ENVIRONMENTAL_ERROR BLAZE_INTERNAL_ERROR) do
      assert is_binary(Status.category(name))
    end
  end

  test "finality" do
    refute Status.final?("in_progress")
    assert Status.final?("succeeded")
    assert Status.final?("disconnected")
  end
end
