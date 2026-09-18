defmodule Conveyor.Bep.Event do
  @moduledoc """
  Helpers for the Build Event Protocol messages Bazel sends over BES.

  A BES `OrderedBuildEvent` wraps a `google.devtools.build.v1.BuildEvent`, which in turn
  carries the Bazel `build_event_stream.BuildEvent` inside a `google.protobuf.Any`.
  This module unwraps that nesting and gives every event a stable `kind` name.
  """

  alias Google.Devtools.Build.V1, as: V1
  alias BuildEventStream.BuildEvent, as: BepEvent

  @bep_type_url "type.googleapis.com/build_event_stream.BuildEvent"

  @type kind ::
          :bazel_event
          | :invocation_attempt_started
          | :invocation_attempt_finished
          | :build_enqueued
          | :build_finished
          | :console_output
          | :component_stream_finished
          | :build_execution_event
          | :source_fetch_event
          | :unknown

  @doc "Returns which variant of the BES `BuildEvent` oneof this is."
  @spec bes_kind(V1.BuildEvent.t()) :: kind()
  def bes_kind(%V1.BuildEvent{event: {kind, _}}), do: kind
  def bes_kind(%V1.BuildEvent{event: nil}), do: :unknown

  @doc """
  Decodes the Bazel event packed inside a BES `BuildEvent`, if it carries one.

  Returns `{:ok, %BuildEventStream.BuildEvent{}}`, `:none` when the BES event is a
  lifecycle/console/stream-control message, or `{:error, reason}` for undecodable payloads.
  """
  @spec unwrap(V1.BuildEvent.t()) :: {:ok, BepEvent.t()} | :none | {:error, term()}
  def unwrap(%V1.BuildEvent{
        event: {:bazel_event, %Google.Protobuf.Any{type_url: @bep_type_url, value: bytes}}
      }) do
    {:ok, BepEvent.decode(bytes)}
  rescue
    e -> {:error, e}
  end

  def unwrap(%V1.BuildEvent{event: {:bazel_event, %Google.Protobuf.Any{type_url: other}}}),
    do: {:error, {:unexpected_type_url, other}}

  def unwrap(%V1.BuildEvent{}), do: :none

  @doc "The payload variant name of a Bazel BEP event, e.g. `:started`, `:progress`, `:finished`."
  @spec payload_kind(BepEvent.t()) :: atom()
  def payload_kind(%BepEvent{payload: {kind, _}}), do: kind
  def payload_kind(%BepEvent{payload: nil}), do: :unknown

  @doc "The id variant name of a Bazel BEP event, e.g. `:started`, `:target_completed`."
  @spec id_kind(BepEvent.t()) :: atom()
  def id_kind(%BepEvent{id: %BuildEventStream.BuildEventId{id: {kind, _}}}), do: kind
  def id_kind(_), do: :unknown

  @doc "Converts a `google.protobuf.Timestamp` to a `DateTime`, or nil."
  @spec to_datetime(Google.Protobuf.Timestamp.t() | nil) :: DateTime.t() | nil
  def to_datetime(nil), do: nil

  def to_datetime(%Google.Protobuf.Timestamp{seconds: s, nanos: n}) do
    DateTime.from_unix!(s * 1_000_000 + div(n, 1_000), :microsecond)
  end

  @doc "Converts a `google.protobuf.Duration` to milliseconds, or nil."
  @spec to_ms(Google.Protobuf.Duration.t() | nil) :: integer() | nil
  def to_ms(nil), do: nil
  def to_ms(%Google.Protobuf.Duration{seconds: s, nanos: n}), do: s * 1_000 + div(n, 1_000_000)
end
