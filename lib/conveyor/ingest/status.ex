defmodule Conveyor.Ingest.Status do
  @moduledoc "Maps Bazel exit codes, abort reasons and stream state to invocation statuses."

  @doc "Status for a `BuildFinished` exit code."
  @spec from_exit_code(String.t() | nil, integer() | nil) :: String.t()
  def from_exit_code(_name, 0), do: "succeeded"
  def from_exit_code("INTERRUPTED", _code), do: "aborted"
  def from_exit_code(_name, 8), do: "aborted"
  def from_exit_code(_name, _code), do: "failed"

  @doc "Human category for the list view: build vs test failure, interrupted, etc."
  @spec category(String.t() | nil) :: String.t() | nil
  def category(nil), do: nil
  def category("SUCCESS"), do: "success"
  def category("TESTS_FAILED"), do: "tests failed"
  def category("NO_TESTS_FOUND"), do: "no tests found"
  def category("BUILD_FAILURE"), do: "build failed"
  def category("PARSING_FAILURE"), do: "parsing failed"
  def category("ANALYSIS_FAILURE"), do: "analysis failed"
  def category("PARTIAL_ANALYSIS_FAILURE"), do: "analysis failed"
  def category("COMMAND_LINE_ERROR"), do: "command line error"
  def category("INTERRUPTED"), do: "interrupted"
  def category("OOM_ERROR"), do: "out of memory"
  def category("REMOTE_ERROR"), do: "remote error"
  def category("REMOTE_ENVIRONMENTAL_ERROR"), do: "remote error"
  def category("LOCAL_ENVIRONMENTAL_ERROR"), do: "local environment error"
  def category("BLAZE_INTERNAL_ERROR"), do: "bazel internal error"
  def category(other), do: other |> String.downcase() |> String.replace("_", " ")

  @doc "Whether a status is terminal."
  @spec final?(String.t()) :: boolean()
  def final?("in_progress"), do: false
  def final?(_), do: true
end
