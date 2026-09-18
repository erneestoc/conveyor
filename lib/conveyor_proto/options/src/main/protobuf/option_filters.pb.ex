defmodule Options.OptionEffectTag do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "options.OptionEffectTag",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :NO_OP, 1
  field :LOSES_INCREMENTAL_STATE, 2
  field :CHANGES_INPUTS, 3
  field :AFFECTS_OUTPUTS, 4
  field :BUILD_FILE_SEMANTICS, 5
  field :BAZEL_INTERNAL_CONFIGURATION, 6
  field :LOADING_AND_ANALYSIS, 7
  field :EXECUTION, 8
  field :HOST_MACHINE_RESOURCE_OPTIMIZATIONS, 9
  field :EAGERNESS_TO_EXIT, 10
  field :BAZEL_MONITORING, 11
  field :TERMINAL_OUTPUT, 12
  field :ACTION_COMMAND_LINES, 13
  field :TEST_RUNNER, 14
end

defmodule Options.OptionMetadataTag do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "options.OptionMetadataTag",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EXPERIMENTAL, 0
  field :INCOMPATIBLE_CHANGE, 1
  field :DEPRECATED, 2
  field :HIDDEN, 3
  field :INTERNAL, 4
  field :NON_CONFIGURABLE, 8
end
