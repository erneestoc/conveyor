defmodule BuildEventStream.TestSize do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build_event_stream.TestSize",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :SMALL, 1
  field :MEDIUM, 2
  field :LARGE, 3
  field :ENORMOUS, 4
end

defmodule BuildEventStream.TestStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build_event_stream.TestStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :NO_STATUS, 0
  field :PASSED, 1
  field :FLAKY, 2
  field :TIMEOUT, 3
  field :FAILED, 4
  field :INCOMPLETE, 5
  field :REMOTE_FAILURE, 6
  field :FAILED_TO_BUILD, 7
  field :TOOL_HALTED_BEFORE_TESTING, 8
end

defmodule BuildEventStream.BuildEventId.FetchId.Downloader do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build_event_stream.BuildEventId.FetchId.Downloader",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :HTTP, 1
  field :GRPC, 2
end

defmodule BuildEventStream.Aborted.AbortReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build_event_stream.Aborted.AbortReason",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :USER_INTERRUPTED, 1
  field :NO_ANALYZE, 8
  field :NO_BUILD, 9
  field :TIME_OUT, 2
  field :REMOTE_ENVIRONMENT_FAILURE, 3
  field :INTERNAL, 4
  field :LOADING_FAILURE, 5
  field :ANALYSIS_FAILURE, 6
  field :SKIPPED, 7
  field :INCOMPLETE, 10
  field :OUT_OF_MEMORY, 11
end

defmodule BuildEventStream.BuildMetrics.WorkerMetrics.WorkerStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build_event_stream.BuildMetrics.WorkerMetrics.WorkerStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :NOT_STARTED, 0
  field :ALIVE, 1
  field :KILLED_DUE_TO_MEMORY_PRESSURE, 2
  field :KILLED_UNKNOWN, 3
  field :KILLED_DUE_TO_INTERRUPTED_EXCEPTION, 4
  field :KILLED_DUE_TO_IO_EXCEPTION, 5
  field :KILLED_DUE_TO_USER_EXEC_EXCEPTION, 6
end

defmodule BuildEventStream.ConvenienceSymlink.Action do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build_event_stream.ConvenienceSymlink.Action",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :CREATE, 1
  field :DELETE, 2
end

defmodule BuildEventStream.BuildEventId.UnknownBuildEventId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.UnknownBuildEventId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :details, 1, type: :string
end

defmodule BuildEventStream.BuildEventId.ProgressId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.ProgressId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :opaque_count, 1, type: :int32, json_name: "opaqueCount"
end

defmodule BuildEventStream.BuildEventId.BuildStartedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.BuildStartedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.UnstructuredCommandLineId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.UnstructuredCommandLineId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.StructuredCommandLineId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.StructuredCommandLineId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :command_line_label, 1, type: :string, json_name: "commandLineLabel"
end

defmodule BuildEventStream.BuildEventId.WorkspaceStatusId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.WorkspaceStatusId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.OptionsParsedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.OptionsParsedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.FetchId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.FetchId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :url, 1, type: :string
  field :downloader, 2, type: BuildEventStream.BuildEventId.FetchId.Downloader, enum: true
end

defmodule BuildEventStream.BuildEventId.PatternExpandedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.PatternExpandedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :pattern, 1, repeated: true, type: :string
end

defmodule BuildEventStream.BuildEventId.WorkspaceConfigId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.WorkspaceConfigId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.BuildMetadataId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.BuildMetadataId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.TargetConfiguredId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.TargetConfiguredId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :aspect, 2, type: :string
end

defmodule BuildEventStream.BuildEventId.NamedSetOfFilesId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.NamedSetOfFilesId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
end

defmodule BuildEventStream.BuildEventId.ConfigurationId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.ConfigurationId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
end

defmodule BuildEventStream.BuildEventId.TargetCompletedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.TargetCompletedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :configuration, 3, type: BuildEventStream.BuildEventId.ConfigurationId
  field :aspect, 2, type: :string
end

defmodule BuildEventStream.BuildEventId.ActionCompletedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.ActionCompletedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :primary_output, 1, type: :string, json_name: "primaryOutput"
  field :label, 2, type: :string
  field :configuration, 3, type: BuildEventStream.BuildEventId.ConfigurationId
end

defmodule BuildEventStream.BuildEventId.UnconfiguredLabelId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.UnconfiguredLabelId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
end

defmodule BuildEventStream.BuildEventId.ConfiguredLabelId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.ConfiguredLabelId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :configuration, 2, type: BuildEventStream.BuildEventId.ConfigurationId
end

defmodule BuildEventStream.BuildEventId.TestResultId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.TestResultId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :configuration, 5, type: BuildEventStream.BuildEventId.ConfigurationId
  field :run, 2, type: :int32
  field :shard, 3, type: :int32
  field :attempt, 4, type: :int32
end

defmodule BuildEventStream.BuildEventId.TestProgressId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.TestProgressId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :configuration, 2, type: BuildEventStream.BuildEventId.ConfigurationId
  field :run, 3, type: :int32
  field :shard, 4, type: :int32
  field :attempt, 5, type: :int32
  field :opaque_count, 6, type: :int32, json_name: "opaqueCount"
end

defmodule BuildEventStream.BuildEventId.TestSummaryId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.TestSummaryId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :configuration, 2, type: BuildEventStream.BuildEventId.ConfigurationId
end

defmodule BuildEventStream.BuildEventId.TargetSummaryId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.TargetSummaryId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :configuration, 2, type: BuildEventStream.BuildEventId.ConfigurationId
end

defmodule BuildEventStream.BuildEventId.BuildFinishedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.BuildFinishedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.BuildToolLogsId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.BuildToolLogsId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.BuildMetricsId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.BuildMetricsId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.ConvenienceSymlinksIdentifiedId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.ConvenienceSymlinksIdentifiedId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId.ExecRequestId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId.ExecRequestId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule BuildEventStream.BuildEventId do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEventId",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:id, 0)

  field :unknown, 1, type: BuildEventStream.BuildEventId.UnknownBuildEventId, oneof: 0
  field :progress, 2, type: BuildEventStream.BuildEventId.ProgressId, oneof: 0
  field :started, 3, type: BuildEventStream.BuildEventId.BuildStartedId, oneof: 0

  field :unstructured_command_line, 11,
    type: BuildEventStream.BuildEventId.UnstructuredCommandLineId,
    json_name: "unstructuredCommandLine",
    oneof: 0

  field :structured_command_line, 18,
    type: BuildEventStream.BuildEventId.StructuredCommandLineId,
    json_name: "structuredCommandLine",
    oneof: 0

  field :workspace_status, 14,
    type: BuildEventStream.BuildEventId.WorkspaceStatusId,
    json_name: "workspaceStatus",
    oneof: 0

  field :options_parsed, 12,
    type: BuildEventStream.BuildEventId.OptionsParsedId,
    json_name: "optionsParsed",
    oneof: 0

  field :fetch, 17, type: BuildEventStream.BuildEventId.FetchId, oneof: 0
  field :configuration, 15, type: BuildEventStream.BuildEventId.ConfigurationId, oneof: 0

  field :target_configured, 16,
    type: BuildEventStream.BuildEventId.TargetConfiguredId,
    json_name: "targetConfigured",
    oneof: 0

  field :pattern, 4, type: BuildEventStream.BuildEventId.PatternExpandedId, oneof: 0

  field :pattern_skipped, 10,
    type: BuildEventStream.BuildEventId.PatternExpandedId,
    json_name: "patternSkipped",
    oneof: 0

  field :named_set, 13,
    type: BuildEventStream.BuildEventId.NamedSetOfFilesId,
    json_name: "namedSet",
    oneof: 0

  field :target_completed, 5,
    type: BuildEventStream.BuildEventId.TargetCompletedId,
    json_name: "targetCompleted",
    oneof: 0

  field :action_completed, 6,
    type: BuildEventStream.BuildEventId.ActionCompletedId,
    json_name: "actionCompleted",
    oneof: 0

  field :unconfigured_label, 19,
    type: BuildEventStream.BuildEventId.UnconfiguredLabelId,
    json_name: "unconfiguredLabel",
    oneof: 0

  field :configured_label, 21,
    type: BuildEventStream.BuildEventId.ConfiguredLabelId,
    json_name: "configuredLabel",
    oneof: 0

  field :test_result, 8,
    type: BuildEventStream.BuildEventId.TestResultId,
    json_name: "testResult",
    oneof: 0

  field :test_progress, 29,
    type: BuildEventStream.BuildEventId.TestProgressId,
    json_name: "testProgress",
    oneof: 0

  field :test_summary, 7,
    type: BuildEventStream.BuildEventId.TestSummaryId,
    json_name: "testSummary",
    oneof: 0

  field :target_summary, 26,
    type: BuildEventStream.BuildEventId.TargetSummaryId,
    json_name: "targetSummary",
    oneof: 0

  field :build_finished, 9,
    type: BuildEventStream.BuildEventId.BuildFinishedId,
    json_name: "buildFinished",
    oneof: 0

  field :build_tool_logs, 20,
    type: BuildEventStream.BuildEventId.BuildToolLogsId,
    json_name: "buildToolLogs",
    oneof: 0

  field :build_metrics, 22,
    type: BuildEventStream.BuildEventId.BuildMetricsId,
    json_name: "buildMetrics",
    oneof: 0

  field :workspace, 23, type: BuildEventStream.BuildEventId.WorkspaceConfigId, oneof: 0

  field :build_metadata, 24,
    type: BuildEventStream.BuildEventId.BuildMetadataId,
    json_name: "buildMetadata",
    oneof: 0

  field :convenience_symlinks_identified, 25,
    type: BuildEventStream.BuildEventId.ConvenienceSymlinksIdentifiedId,
    json_name: "convenienceSymlinksIdentified",
    oneof: 0

  field :exec_request, 28,
    type: BuildEventStream.BuildEventId.ExecRequestId,
    json_name: "execRequest",
    oneof: 0
end

defmodule BuildEventStream.Progress do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.Progress",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :stdout, 1, type: :string
  field :stderr, 2, type: :string
end

defmodule BuildEventStream.Aborted do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.Aborted",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reason, 1, type: BuildEventStream.Aborted.AbortReason, enum: true
  field :description, 2, type: :string
end

defmodule BuildEventStream.BuildStarted do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildStarted",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :uuid, 1, type: :string
  field :start_time_millis, 2, type: :int64, json_name: "startTimeMillis", deprecated: true
  field :start_time, 9, type: Google.Protobuf.Timestamp, json_name: "startTime"
  field :build_tool_version, 3, type: :string, json_name: "buildToolVersion"
  field :options_description, 4, type: :string, json_name: "optionsDescription"
  field :command, 5, type: :string
  field :working_directory, 6, type: :string, json_name: "workingDirectory"
  field :workspace_directory, 7, type: :string, json_name: "workspaceDirectory"
  field :server_pid, 8, type: :int64, json_name: "serverPid"
  field :host, 10, type: :string
  field :user, 11, type: :string
end

defmodule BuildEventStream.WorkspaceConfig do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.WorkspaceConfig",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :local_exec_root, 1, type: :string, json_name: "localExecRoot"
end

defmodule BuildEventStream.UnstructuredCommandLine do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.UnstructuredCommandLine",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :args, 1, repeated: true, type: :string
end

defmodule BuildEventStream.OptionsParsed do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.OptionsParsed",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :startup_options, 1, repeated: true, type: :string, json_name: "startupOptions"

  field :explicit_startup_options, 2,
    repeated: true,
    type: :string,
    json_name: "explicitStartupOptions"

  field :cmd_line, 3, repeated: true, type: :string, json_name: "cmdLine"
  field :explicit_cmd_line, 4, repeated: true, type: :string, json_name: "explicitCmdLine"

  field :invocation_policy, 5,
    type: Blaze.InvocationPolicy.InvocationPolicy,
    json_name: "invocationPolicy"

  field :tool_tag, 6, type: :string, json_name: "toolTag"
end

defmodule BuildEventStream.Fetch do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.Fetch",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
end

defmodule BuildEventStream.WorkspaceStatus.Item do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.WorkspaceStatus.Item",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule BuildEventStream.WorkspaceStatus do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.WorkspaceStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :item, 1, repeated: true, type: BuildEventStream.WorkspaceStatus.Item
end

defmodule BuildEventStream.BuildMetadata.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetadata.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule BuildEventStream.BuildMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetadata",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :metadata, 1,
    repeated: true,
    type: BuildEventStream.BuildMetadata.MetadataEntry,
    map: true
end

defmodule BuildEventStream.Configuration.MakeVariableEntry do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.Configuration.MakeVariableEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule BuildEventStream.Configuration do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.Configuration",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :mnemonic, 1, type: :string
  field :platform_name, 2, type: :string, json_name: "platformName"
  field :cpu, 3, type: :string

  field :make_variable, 4,
    repeated: true,
    type: BuildEventStream.Configuration.MakeVariableEntry,
    json_name: "makeVariable",
    map: true

  field :is_tool, 5, type: :bool, json_name: "isTool"
end

defmodule BuildEventStream.PatternExpanded.TestSuiteExpansion do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.PatternExpanded.TestSuiteExpansion",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :suite_label, 1, type: :string, json_name: "suiteLabel"
  field :test_labels, 2, repeated: true, type: :string, json_name: "testLabels"
end

defmodule BuildEventStream.PatternExpanded do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.PatternExpanded",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :test_suite_expansions, 1,
    repeated: true,
    type: BuildEventStream.PatternExpanded.TestSuiteExpansion,
    json_name: "testSuiteExpansions"
end

defmodule BuildEventStream.TargetConfigured do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TargetConfigured",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :target_kind, 1, type: :string, json_name: "targetKind"
  field :test_size, 2, type: BuildEventStream.TestSize, json_name: "testSize", enum: true
  field :tag, 3, repeated: true, type: :string
end

defmodule BuildEventStream.File do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.File",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:file, 0)

  field :path_prefix, 4, repeated: true, type: :string, json_name: "pathPrefix"
  field :name, 1, type: :string
  field :uri, 2, type: :string, oneof: 0
  field :contents, 3, type: :bytes, oneof: 0
  field :symlink_target_path, 7, type: :string, json_name: "symlinkTargetPath", oneof: 0
  field :digest, 5, type: :string
  field :length, 6, type: :int64
end

defmodule BuildEventStream.NamedSetOfFiles do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.NamedSetOfFiles",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :files, 1, repeated: true, type: BuildEventStream.File

  field :file_sets, 2,
    repeated: true,
    type: BuildEventStream.BuildEventId.NamedSetOfFilesId,
    json_name: "fileSets"
end

defmodule BuildEventStream.ActionExecuted do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.ActionExecuted",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :type, 8, type: :string
  field :exit_code, 2, type: :int32, json_name: "exitCode"
  field :stdout, 3, type: BuildEventStream.File
  field :stderr, 4, type: BuildEventStream.File
  field :label, 5, type: :string, deprecated: true
  field :configuration, 7, type: BuildEventStream.BuildEventId.ConfigurationId, deprecated: true
  field :primary_output, 6, type: BuildEventStream.File, json_name: "primaryOutput"
  field :command_line, 9, repeated: true, type: :string, json_name: "commandLine"
  field :failure_detail, 11, type: FailureDetails.FailureDetail, json_name: "failureDetail"
  field :start_time, 12, type: Google.Protobuf.Timestamp, json_name: "startTime"
  field :end_time, 13, type: Google.Protobuf.Timestamp, json_name: "endTime"

  field :strategy_details, 14,
    repeated: true,
    type: Google.Protobuf.Any,
    json_name: "strategyDetails"
end

defmodule BuildEventStream.OutputGroup do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.OutputGroup",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string

  field :file_sets, 3,
    repeated: true,
    type: BuildEventStream.BuildEventId.NamedSetOfFilesId,
    json_name: "fileSets"

  field :incomplete, 4, type: :bool
  field :inline_files, 5, repeated: true, type: BuildEventStream.File, json_name: "inlineFiles"
end

defmodule BuildEventStream.TargetComplete do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TargetComplete",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :target_kind, 5, type: :string, json_name: "targetKind", deprecated: true

  field :test_size, 6,
    type: BuildEventStream.TestSize,
    json_name: "testSize",
    enum: true,
    deprecated: true

  field :output_group, 2,
    repeated: true,
    type: BuildEventStream.OutputGroup,
    json_name: "outputGroup"

  field :important_output, 4,
    repeated: true,
    type: BuildEventStream.File,
    json_name: "importantOutput",
    deprecated: true

  field :directory_output, 8,
    repeated: true,
    type: BuildEventStream.File,
    json_name: "directoryOutput"

  field :tag, 3, repeated: true, type: :string
  field :test_timeout_seconds, 7, type: :int64, json_name: "testTimeoutSeconds", deprecated: true
  field :test_timeout, 10, type: Google.Protobuf.Duration, json_name: "testTimeout"
  field :failure_detail, 9, type: FailureDetails.FailureDetail, json_name: "failureDetail"
end

defmodule BuildEventStream.TestResult.ExecutionInfo.TimingBreakdown do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TestResult.ExecutionInfo.TimingBreakdown",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :child, 1, repeated: true, type: BuildEventStream.TestResult.ExecutionInfo.TimingBreakdown
  field :name, 2, type: :string
  field :time_millis, 3, type: :int64, json_name: "timeMillis", deprecated: true
  field :time, 4, type: Google.Protobuf.Duration
end

defmodule BuildEventStream.TestResult.ExecutionInfo.ResourceUsage do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TestResult.ExecutionInfo.ResourceUsage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :int64
end

defmodule BuildEventStream.TestResult.ExecutionInfo do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TestResult.ExecutionInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :timeout_seconds, 1, type: :int32, json_name: "timeoutSeconds", deprecated: true
  field :strategy, 2, type: :string
  field :cached_remotely, 6, type: :bool, json_name: "cachedRemotely"
  field :exit_code, 7, type: :int32, json_name: "exitCode"
  field :hostname, 3, type: :string

  field :timing_breakdown, 4,
    type: BuildEventStream.TestResult.ExecutionInfo.TimingBreakdown,
    json_name: "timingBreakdown"

  field :resource_usage, 5,
    repeated: true,
    type: BuildEventStream.TestResult.ExecutionInfo.ResourceUsage,
    json_name: "resourceUsage"
end

defmodule BuildEventStream.TestResult do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TestResult",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :status, 5, type: BuildEventStream.TestStatus, enum: true
  field :status_details, 9, type: :string, json_name: "statusDetails"
  field :cached_locally, 4, type: :bool, json_name: "cachedLocally"

  field :test_attempt_start_millis_epoch, 6,
    type: :int64,
    json_name: "testAttemptStartMillisEpoch",
    deprecated: true

  field :test_attempt_start, 10, type: Google.Protobuf.Timestamp, json_name: "testAttemptStart"

  field :test_attempt_duration_millis, 3,
    type: :int64,
    json_name: "testAttemptDurationMillis",
    deprecated: true

  field :test_attempt_duration, 11,
    type: Google.Protobuf.Duration,
    json_name: "testAttemptDuration"

  field :test_action_output, 2,
    repeated: true,
    type: BuildEventStream.File,
    json_name: "testActionOutput"

  field :warning, 7, repeated: true, type: :string

  field :execution_info, 8,
    type: BuildEventStream.TestResult.ExecutionInfo,
    json_name: "executionInfo"
end

defmodule BuildEventStream.TestProgress do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TestProgress",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :uri, 1, type: :string
end

defmodule BuildEventStream.TestSummary do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TestSummary",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :overall_status, 5,
    type: BuildEventStream.TestStatus,
    json_name: "overallStatus",
    enum: true

  field :total_run_count, 1, type: :int32, json_name: "totalRunCount"
  field :run_count, 10, type: :int32, json_name: "runCount"
  field :attempt_count, 15, type: :int32, json_name: "attemptCount"
  field :shard_count, 11, type: :int32, json_name: "shardCount"
  field :passed, 3, repeated: true, type: BuildEventStream.File
  field :failed, 4, repeated: true, type: BuildEventStream.File
  field :total_num_cached, 6, type: :int32, json_name: "totalNumCached"

  field :first_start_time_millis, 7,
    type: :int64,
    json_name: "firstStartTimeMillis",
    deprecated: true

  field :first_start_time, 13, type: Google.Protobuf.Timestamp, json_name: "firstStartTime"
  field :last_stop_time_millis, 8, type: :int64, json_name: "lastStopTimeMillis", deprecated: true
  field :last_stop_time, 14, type: Google.Protobuf.Timestamp, json_name: "lastStopTime"

  field :total_run_duration_millis, 9,
    type: :int64,
    json_name: "totalRunDurationMillis",
    deprecated: true

  field :total_run_duration, 12, type: Google.Protobuf.Duration, json_name: "totalRunDuration"
end

defmodule BuildEventStream.TargetSummary do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.TargetSummary",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :overall_build_success, 1, type: :bool, json_name: "overallBuildSuccess"

  field :overall_test_status, 2,
    type: BuildEventStream.TestStatus,
    json_name: "overallTestStatus",
    enum: true
end

defmodule BuildEventStream.BuildFinished.ExitCode do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildFinished.ExitCode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :code, 2, type: :int32
end

defmodule BuildEventStream.BuildFinished.AnomalyReport do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildFinished.AnomalyReport",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :was_suspended, 1, type: :bool, json_name: "wasSuspended"
end

defmodule BuildEventStream.BuildFinished do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildFinished",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :overall_success, 1, type: :bool, json_name: "overallSuccess", deprecated: true
  field :exit_code, 3, type: BuildEventStream.BuildFinished.ExitCode, json_name: "exitCode"
  field :finish_time_millis, 2, type: :int64, json_name: "finishTimeMillis", deprecated: true
  field :finish_time, 5, type: Google.Protobuf.Timestamp, json_name: "finishTime"

  field :anomaly_report, 4,
    type: BuildEventStream.BuildFinished.AnomalyReport,
    json_name: "anomalyReport",
    deprecated: true

  field :failure_detail, 6, type: FailureDetails.FailureDetail, json_name: "failureDetail"
end

defmodule BuildEventStream.BuildMetrics.ActionSummary.ActionData do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.ActionSummary.ActionData",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :mnemonic, 1, type: :string
  field :actions_executed, 2, type: :int64, json_name: "actionsExecuted"
  field :first_started_ms, 3, type: :int64, json_name: "firstStartedMs"
  field :last_ended_ms, 4, type: :int64, json_name: "lastEndedMs"
  field :system_time, 5, type: Google.Protobuf.Duration, json_name: "systemTime"
  field :user_time, 6, type: Google.Protobuf.Duration, json_name: "userTime"
  field :actions_created, 7, type: :int64, json_name: "actionsCreated"
end

defmodule BuildEventStream.BuildMetrics.ActionSummary.RunnerCount do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.ActionSummary.RunnerCount",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :count, 2, type: :int32
  field :exec_kind, 3, type: :string, json_name: "execKind"
end

defmodule BuildEventStream.BuildMetrics.ActionSummary do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.ActionSummary",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :actions_created, 1, type: :int64, json_name: "actionsCreated"

  field :actions_created_not_including_aspects, 3,
    type: :int64,
    json_name: "actionsCreatedNotIncludingAspects"

  field :actions_executed, 2, type: :int64, json_name: "actionsExecuted"

  field :action_data, 4,
    repeated: true,
    type: BuildEventStream.BuildMetrics.ActionSummary.ActionData,
    json_name: "actionData"

  field :remote_cache_hits, 5, type: :int64, json_name: "remoteCacheHits", deprecated: true

  field :runner_count, 6,
    repeated: true,
    type: BuildEventStream.BuildMetrics.ActionSummary.RunnerCount,
    json_name: "runnerCount"

  field :action_cache_statistics, 7,
    type: Blaze.ActionCacheStatistics,
    json_name: "actionCacheStatistics"
end

defmodule BuildEventStream.BuildMetrics.MemoryMetrics.GarbageMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.MemoryMetrics.GarbageMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :type, 1, type: :string
  field :garbage_collected, 2, type: :int64, json_name: "garbageCollected"
end

defmodule BuildEventStream.BuildMetrics.MemoryMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.MemoryMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :used_heap_size_post_build, 1, type: :int64, json_name: "usedHeapSizePostBuild"
  field :peak_post_gc_heap_size, 2, type: :int64, json_name: "peakPostGcHeapSize"

  field :peak_post_gc_tenured_space_heap_size, 4,
    type: :int64,
    json_name: "peakPostGcTenuredSpaceHeapSize"

  field :garbage_metrics, 3,
    repeated: true,
    type: BuildEventStream.BuildMetrics.MemoryMetrics.GarbageMetrics,
    json_name: "garbageMetrics"
end

defmodule BuildEventStream.BuildMetrics.TargetMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.TargetMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :targets_loaded, 1, type: :int64, json_name: "targetsLoaded"
  field :targets_configured, 2, type: :int64, json_name: "targetsConfigured"

  field :targets_configured_not_including_aspects, 3,
    type: :int64,
    json_name: "targetsConfiguredNotIncludingAspects"
end

defmodule BuildEventStream.BuildMetrics.PackageMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.PackageMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :packages_loaded, 1, type: :int64, json_name: "packagesLoaded"

  field :package_load_metrics, 2,
    repeated: true,
    type: Devtools.Build.Lib.Packages.Metrics.PackageLoadMetrics,
    json_name: "packageLoadMetrics"
end

defmodule BuildEventStream.BuildMetrics.TimingMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.TimingMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :cpu_time_in_ms, 1, type: :int64, json_name: "cpuTimeInMs"
  field :wall_time_in_ms, 2, type: :int64, json_name: "wallTimeInMs"
  field :analysis_phase_time_in_ms, 3, type: :int64, json_name: "analysisPhaseTimeInMs"
  field :execution_phase_time_in_ms, 4, type: :int64, json_name: "executionPhaseTimeInMs"
  field :actions_execution_start_in_ms, 5, type: :int64, json_name: "actionsExecutionStartInMs"
  field :critical_path_time, 6, type: Google.Protobuf.Duration, json_name: "criticalPathTime"
end

defmodule BuildEventStream.BuildMetrics.CumulativeMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.CumulativeMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :num_analyses, 11, type: :int32, json_name: "numAnalyses"
  field :num_builds, 12, type: :int32, json_name: "numBuilds"
end

defmodule BuildEventStream.BuildMetrics.ArtifactMetrics.FilesMetric do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.ArtifactMetrics.FilesMetric",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :size_in_bytes, 1, type: :int64, json_name: "sizeInBytes"
  field :count, 2, type: :int32
end

defmodule BuildEventStream.BuildMetrics.ArtifactMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.ArtifactMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :source_artifacts_read, 2,
    type: BuildEventStream.BuildMetrics.ArtifactMetrics.FilesMetric,
    json_name: "sourceArtifactsRead"

  field :output_artifacts_seen, 3,
    type: BuildEventStream.BuildMetrics.ArtifactMetrics.FilesMetric,
    json_name: "outputArtifactsSeen"

  field :output_artifacts_from_action_cache, 4,
    type: BuildEventStream.BuildMetrics.ArtifactMetrics.FilesMetric,
    json_name: "outputArtifactsFromActionCache"

  field :top_level_artifacts, 5,
    type: BuildEventStream.BuildMetrics.ArtifactMetrics.FilesMetric,
    json_name: "topLevelArtifacts"
end

defmodule BuildEventStream.BuildMetrics.EvaluationStat do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.EvaluationStat",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :skyfunction_name, 1, type: :string, json_name: "skyfunctionName"
  field :count, 2, type: :int64
end

defmodule BuildEventStream.BuildMetrics.BuildGraphMetrics.RuleClassCount do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.BuildGraphMetrics.RuleClassCount",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :rule_class, 2, type: :string, json_name: "ruleClass"
  field :count, 3, type: :uint64
  field :action_count, 4, type: :uint64, json_name: "actionCount"
end

defmodule BuildEventStream.BuildMetrics.BuildGraphMetrics.AspectCount do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.BuildGraphMetrics.AspectCount",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :aspect_name, 2, type: :string, json_name: "aspectName"
  field :count, 3, type: :uint64
  field :action_count, 4, type: :uint64, json_name: "actionCount"
end

defmodule BuildEventStream.BuildMetrics.BuildGraphMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.BuildGraphMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :action_lookup_value_count, 1, type: :int32, json_name: "actionLookupValueCount"

  field :action_lookup_value_count_not_including_aspects, 5,
    type: :int32,
    json_name: "actionLookupValueCountNotIncludingAspects"

  field :action_count, 2, type: :int32, json_name: "actionCount"

  field :action_count_not_including_aspects, 6,
    type: :int32,
    json_name: "actionCountNotIncludingAspects"

  field :input_file_configured_target_count, 7,
    type: :int32,
    json_name: "inputFileConfiguredTargetCount"

  field :output_file_configured_target_count, 8,
    type: :int32,
    json_name: "outputFileConfiguredTargetCount"

  field :other_configured_target_count, 9, type: :int32, json_name: "otherConfiguredTargetCount"
  field :output_artifact_count, 3, type: :int32, json_name: "outputArtifactCount"

  field :post_invocation_skyframe_node_count, 4,
    type: :int32,
    json_name: "postInvocationSkyframeNodeCount"

  field :dirtied_values, 10,
    repeated: true,
    type: BuildEventStream.BuildMetrics.EvaluationStat,
    json_name: "dirtiedValues"

  field :changed_values, 11,
    repeated: true,
    type: BuildEventStream.BuildMetrics.EvaluationStat,
    json_name: "changedValues"

  field :built_values, 12,
    repeated: true,
    type: BuildEventStream.BuildMetrics.EvaluationStat,
    json_name: "builtValues"

  field :cleaned_values, 13,
    repeated: true,
    type: BuildEventStream.BuildMetrics.EvaluationStat,
    json_name: "cleanedValues"

  field :evaluated_values, 17,
    repeated: true,
    type: BuildEventStream.BuildMetrics.EvaluationStat,
    json_name: "evaluatedValues"

  field :rule_class, 14,
    repeated: true,
    type: BuildEventStream.BuildMetrics.BuildGraphMetrics.RuleClassCount,
    json_name: "ruleClass"

  field :aspect, 15,
    repeated: true,
    type: BuildEventStream.BuildMetrics.BuildGraphMetrics.AspectCount
end

defmodule BuildEventStream.BuildMetrics.WorkerMetrics.WorkerStats do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.WorkerMetrics.WorkerStats",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :collect_time_in_ms, 1, type: :int64, json_name: "collectTimeInMs"
  field :worker_memory_in_kb, 2, type: :int32, json_name: "workerMemoryInKb"
  field :prior_worker_memory_in_kb, 4, type: :int32, json_name: "priorWorkerMemoryInKb"
  field :last_action_start_time_in_ms, 3, type: :int64, json_name: "lastActionStartTimeInMs"
end

defmodule BuildEventStream.BuildMetrics.WorkerMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.WorkerMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :worker_id, 1, type: :int32, json_name: "workerId", deprecated: true
  field :worker_ids, 8, repeated: true, type: :uint32, json_name: "workerIds"
  field :process_id, 2, type: :uint32, json_name: "processId"
  field :mnemonic, 3, type: :string
  field :is_multiplex, 4, type: :bool, json_name: "isMultiplex"
  field :is_sandbox, 5, type: :bool, json_name: "isSandbox"
  field :is_measurable, 6, type: :bool, json_name: "isMeasurable"
  field :worker_key_hash, 9, type: :int64, json_name: "workerKeyHash"

  field :worker_status, 10,
    type: BuildEventStream.BuildMetrics.WorkerMetrics.WorkerStatus,
    json_name: "workerStatus",
    enum: true

  field :code, 12, proto3_optional: true, type: FailureDetails.Worker.Code, enum: true
  field :actions_executed, 11, type: :int64, json_name: "actionsExecuted"
  field :prior_actions_executed, 13, type: :int64, json_name: "priorActionsExecuted"

  field :worker_stats, 7,
    repeated: true,
    type: BuildEventStream.BuildMetrics.WorkerMetrics.WorkerStats,
    json_name: "workerStats"
end

defmodule BuildEventStream.BuildMetrics.NetworkMetrics.SystemNetworkStats do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.NetworkMetrics.SystemNetworkStats",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :bytes_sent, 1, type: :uint64, json_name: "bytesSent"
  field :bytes_recv, 2, type: :uint64, json_name: "bytesRecv"
  field :packets_sent, 3, type: :uint64, json_name: "packetsSent"
  field :packets_recv, 4, type: :uint64, json_name: "packetsRecv"
  field :peak_bytes_sent_per_sec, 5, type: :uint64, json_name: "peakBytesSentPerSec"
  field :peak_bytes_recv_per_sec, 6, type: :uint64, json_name: "peakBytesRecvPerSec"
  field :peak_packets_sent_per_sec, 7, type: :uint64, json_name: "peakPacketsSentPerSec"
  field :peak_packets_recv_per_sec, 8, type: :uint64, json_name: "peakPacketsRecvPerSec"
end

defmodule BuildEventStream.BuildMetrics.NetworkMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.NetworkMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :system_network_stats, 1,
    type: BuildEventStream.BuildMetrics.NetworkMetrics.SystemNetworkStats,
    json_name: "systemNetworkStats"
end

defmodule BuildEventStream.BuildMetrics.WorkerPoolMetrics.WorkerPoolStats do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.WorkerPoolMetrics.WorkerPoolStats",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hash, 1, type: :int32
  field :mnemonic, 2, type: :string
  field :created_count, 3, type: :int64, json_name: "createdCount"
  field :destroyed_count, 4, type: :int64, json_name: "destroyedCount"
  field :evicted_count, 5, type: :int64, json_name: "evictedCount"

  field :user_exec_exception_destroyed_count, 6,
    type: :int64,
    json_name: "userExecExceptionDestroyedCount"

  field :io_exception_destroyed_count, 7, type: :int64, json_name: "ioExceptionDestroyedCount"

  field :interrupted_exception_destroyed_count, 8,
    type: :int64,
    json_name: "interruptedExceptionDestroyedCount"

  field :unknown_destroyed_count, 9, type: :int64, json_name: "unknownDestroyedCount"
  field :alive_count, 10, type: :int64, json_name: "aliveCount"
end

defmodule BuildEventStream.BuildMetrics.WorkerPoolMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.WorkerPoolMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :worker_pool_stats, 1,
    repeated: true,
    type: BuildEventStream.BuildMetrics.WorkerPoolMetrics.WorkerPoolStats,
    json_name: "workerPoolStats"
end

defmodule BuildEventStream.BuildMetrics.DynamicExecutionMetrics.RaceStatistics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.DynamicExecutionMetrics.RaceStatistics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :mnemonic, 1, type: :string
  field :local_runner, 2, type: :string, json_name: "localRunner"
  field :remote_runner, 3, type: :string, json_name: "remoteRunner"
  field :local_wins, 4, type: :int32, json_name: "localWins"
  field :remote_wins, 5, type: :int32, json_name: "remoteWins"
end

defmodule BuildEventStream.BuildMetrics.DynamicExecutionMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.DynamicExecutionMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :race_statistics, 1,
    repeated: true,
    type: BuildEventStream.BuildMetrics.DynamicExecutionMetrics.RaceStatistics,
    json_name: "raceStatistics"
end

defmodule BuildEventStream.BuildMetrics.RemoteAnalysisCacheStatistics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics.RemoteAnalysisCacheStatistics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :cache_hits, 1, type: :int64, json_name: "cacheHits"
  field :cache_misses, 2, type: :int64, json_name: "cacheMisses"

  field :value_store_value_bytes_received, 3,
    type: :int64,
    json_name: "valueStoreValueBytesReceived"

  field :value_store_value_bytes_sent, 4, type: :int64, json_name: "valueStoreValueBytesSent"
  field :value_store_key_bytes_sent, 5, type: :int64, json_name: "valueStoreKeyBytesSent"
  field :value_store_write_ops, 6, type: :int64, json_name: "valueStoreWriteOps"

  field :value_store_read_ops_successful, 7,
    type: :int64,
    json_name: "valueStoreReadOpsSuccessful"

  field :value_store_read_ops_not_found, 8, type: :int64, json_name: "valueStoreReadOpsNotFound"
  field :value_store_read_batches, 10, type: :int64, json_name: "valueStoreReadBatches"
  field :value_store_write_batches, 11, type: :int64, json_name: "valueStoreWriteBatches"
  field :analysis_cache_bytes_received, 12, type: :int64, json_name: "analysisCacheBytesReceived"
  field :analysis_cache_key_bytes_sent, 13, type: :int64, json_name: "analysisCacheKeyBytesSent"
  field :analysis_cache_ops, 14, type: :int64, json_name: "analysisCacheOps"
  field :analysis_cache_batches, 15, type: :int64, json_name: "analysisCacheBatches"
end

defmodule BuildEventStream.BuildMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :action_summary, 1,
    type: BuildEventStream.BuildMetrics.ActionSummary,
    json_name: "actionSummary"

  field :memory_metrics, 2,
    type: BuildEventStream.BuildMetrics.MemoryMetrics,
    json_name: "memoryMetrics"

  field :target_metrics, 3,
    type: BuildEventStream.BuildMetrics.TargetMetrics,
    json_name: "targetMetrics"

  field :package_metrics, 4,
    type: BuildEventStream.BuildMetrics.PackageMetrics,
    json_name: "packageMetrics"

  field :timing_metrics, 5,
    type: BuildEventStream.BuildMetrics.TimingMetrics,
    json_name: "timingMetrics"

  field :cumulative_metrics, 6,
    type: BuildEventStream.BuildMetrics.CumulativeMetrics,
    json_name: "cumulativeMetrics"

  field :artifact_metrics, 7,
    type: BuildEventStream.BuildMetrics.ArtifactMetrics,
    json_name: "artifactMetrics"

  field :build_graph_metrics, 8,
    type: BuildEventStream.BuildMetrics.BuildGraphMetrics,
    json_name: "buildGraphMetrics"

  field :worker_metrics, 9,
    repeated: true,
    type: BuildEventStream.BuildMetrics.WorkerMetrics,
    json_name: "workerMetrics"

  field :network_metrics, 10,
    type: BuildEventStream.BuildMetrics.NetworkMetrics,
    json_name: "networkMetrics"

  field :worker_pool_metrics, 11,
    type: BuildEventStream.BuildMetrics.WorkerPoolMetrics,
    json_name: "workerPoolMetrics"

  field :dynamic_execution_metrics, 12,
    type: BuildEventStream.BuildMetrics.DynamicExecutionMetrics,
    json_name: "dynamicExecutionMetrics"

  field :remote_analysis_cache_statistics, 13,
    type: BuildEventStream.BuildMetrics.RemoteAnalysisCacheStatistics,
    json_name: "remoteAnalysisCacheStatistics"
end

defmodule BuildEventStream.BuildToolLogs do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildToolLogs",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :log, 1, repeated: true, type: BuildEventStream.File
end

defmodule BuildEventStream.ConvenienceSymlinksIdentified do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.ConvenienceSymlinksIdentified",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :convenience_symlinks, 1,
    repeated: true,
    type: BuildEventStream.ConvenienceSymlink,
    json_name: "convenienceSymlinks"
end

defmodule BuildEventStream.ConvenienceSymlink do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.ConvenienceSymlink",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :action, 2, type: BuildEventStream.ConvenienceSymlink.Action, enum: true
  field :target, 3, type: :string
end

defmodule BuildEventStream.ExecRequestConstructed do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.ExecRequestConstructed",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :working_directory, 1, type: :bytes, json_name: "workingDirectory"
  field :argv, 2, repeated: true, type: :bytes

  field :environment_variable, 3,
    repeated: true,
    type: BuildEventStream.EnvironmentVariable,
    json_name: "environmentVariable"

  field :environment_variable_to_clear, 4,
    repeated: true,
    type: :bytes,
    json_name: "environmentVariableToClear"

  field :should_exec, 5, type: :bool, json_name: "shouldExec"
end

defmodule BuildEventStream.EnvironmentVariable do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.EnvironmentVariable",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :bytes
  field :value, 2, type: :bytes
end

defmodule BuildEventStream.BuildEvent do
  @moduledoc false

  use Protobuf,
    full_name: "build_event_stream.BuildEvent",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:payload, 0)

  field :id, 1, type: BuildEventStream.BuildEventId
  field :children, 2, repeated: true, type: BuildEventStream.BuildEventId
  field :last_message, 20, type: :bool, json_name: "lastMessage"
  field :progress, 3, type: BuildEventStream.Progress, oneof: 0
  field :aborted, 4, type: BuildEventStream.Aborted, oneof: 0
  field :started, 5, type: BuildEventStream.BuildStarted, oneof: 0

  field :unstructured_command_line, 12,
    type: BuildEventStream.UnstructuredCommandLine,
    json_name: "unstructuredCommandLine",
    oneof: 0

  field :structured_command_line, 22,
    type: CommandLine.CommandLine,
    json_name: "structuredCommandLine",
    oneof: 0

  field :options_parsed, 13,
    type: BuildEventStream.OptionsParsed,
    json_name: "optionsParsed",
    oneof: 0

  field :workspace_status, 16,
    type: BuildEventStream.WorkspaceStatus,
    json_name: "workspaceStatus",
    oneof: 0

  field :fetch, 21, type: BuildEventStream.Fetch, oneof: 0
  field :configuration, 17, type: BuildEventStream.Configuration, oneof: 0
  field :expanded, 6, type: BuildEventStream.PatternExpanded, oneof: 0
  field :configured, 18, type: BuildEventStream.TargetConfigured, oneof: 0
  field :action, 7, type: BuildEventStream.ActionExecuted, oneof: 0

  field :named_set_of_files, 15,
    type: BuildEventStream.NamedSetOfFiles,
    json_name: "namedSetOfFiles",
    oneof: 0

  field :completed, 8, type: BuildEventStream.TargetComplete, oneof: 0
  field :test_result, 10, type: BuildEventStream.TestResult, json_name: "testResult", oneof: 0

  field :test_progress, 30,
    type: BuildEventStream.TestProgress,
    json_name: "testProgress",
    oneof: 0

  field :test_summary, 9, type: BuildEventStream.TestSummary, json_name: "testSummary", oneof: 0

  field :target_summary, 28,
    type: BuildEventStream.TargetSummary,
    json_name: "targetSummary",
    oneof: 0

  field :finished, 14, type: BuildEventStream.BuildFinished, oneof: 0

  field :build_tool_logs, 23,
    type: BuildEventStream.BuildToolLogs,
    json_name: "buildToolLogs",
    oneof: 0

  field :build_metrics, 24,
    type: BuildEventStream.BuildMetrics,
    json_name: "buildMetrics",
    oneof: 0

  field :workspace_info, 25,
    type: BuildEventStream.WorkspaceConfig,
    json_name: "workspaceInfo",
    oneof: 0

  field :build_metadata, 26,
    type: BuildEventStream.BuildMetadata,
    json_name: "buildMetadata",
    oneof: 0

  field :convenience_symlinks_identified, 27,
    type: BuildEventStream.ConvenienceSymlinksIdentified,
    json_name: "convenienceSymlinksIdentified",
    oneof: 0

  field :exec_request, 29,
    type: BuildEventStream.ExecRequestConstructed,
    json_name: "execRequest",
    oneof: 0
end
