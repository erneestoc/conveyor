defmodule FailureDetails.Interrupted.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Interrupted.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :INTERRUPTED_UNKNOWN, 0
  field :INTERRUPTED, 28
  field :DEPRECATED_BUILD, 4
  field :DEPRECATED_BUILD_COMPLETION, 5
  field :DEPRECATED_PACKAGE_LOADING_SYNC, 6
  field :DEPRECATED_EXECUTOR_COMPLETION, 7
  field :DEPRECATED_COMMAND_DISPATCH, 8
  field :DEPRECATED_INFO_ITEM, 9
  field :DEPRECATED_AFTER_QUERY, 10
  field :DEPRECATED_FETCH_COMMAND, 17
  field :DEPRECATED_SYNC_COMMAND, 18
  field :DEPRECATED_CLEAN_COMMAND, 20
  field :DEPRECATED_MOBILE_INSTALL_COMMAND, 21
  field :DEPRECATED_QUERY, 22
  field :DEPRECATED_RUN_COMMAND, 23
  field :DEPRECATED_OPTIONS_PARSING, 27
end

defmodule FailureDetails.Spawn.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Spawn.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :SPAWN_UNKNOWN, 0
  field :NON_ZERO_EXIT, 1
  field :TIMEOUT, 2
  field :OUT_OF_MEMORY, 3
  field :EXECUTION_FAILED, 4
  field :EXECUTION_DENIED, 5
  field :REMOTE_CACHE_FAILED, 6
  field :COMMAND_LINE_EXPANSION_FAILURE, 7
  field :EXEC_IO_EXCEPTION, 8
  field :INVALID_TIMEOUT, 9
  field :INVALID_REMOTE_EXECUTION_PROPERTIES, 10
  field :NO_USABLE_STRATEGY_FOUND, 11
  field :UNSPECIFIED_EXECUTION_FAILURE, 12
  field :FORBIDDEN_INPUT, 13
  field :REMOTE_CACHE_EVICTED, 14
  field :SPAWN_LOG_IO_EXCEPTION, 15
end

defmodule FailureDetails.ExternalRepository.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ExternalRepository.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EXTERNAL_REPOSITORY_UNKNOWN, 0
  field :OVERRIDE_DISALLOWED_MANAGED_DIRECTORIES, 1
  field :BAD_DOWNLOADER_CONFIG, 2
  field :REPOSITORY_MAPPING_RESOLUTION_FAILED, 3
  field :CREDENTIALS_INIT_FAILURE, 4
  field :BAD_REPO_CONTENTS_CACHE, 5
  field :UNKNOWN_REGISTRY, 6
  field :SYMLINKING_FAILED, 7
end

defmodule FailureDetails.BuildProgress.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.BuildProgress.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :BUILD_PROGRESS_UNKNOWN, 0
  field :OUTPUT_INITIALIZATION, 3
  field :BES_RUNS_PER_TEST_LIMIT_UNSUPPORTED, 4
  field :BES_LOCAL_WRITE_ERROR, 5
  field :BES_INITIALIZATION_ERROR, 6
  field :BES_UPLOAD_TIMEOUT_ERROR, 7
  field :BES_FILE_WRITE_TIMEOUT, 8
  field :BES_FILE_WRITE_IO_ERROR, 9
  field :BES_FILE_WRITE_INTERRUPTED, 10
  field :BES_FILE_WRITE_CANCELED, 11
  field :BES_FILE_WRITE_UNKNOWN_ERROR, 12
  field :BES_UPLOAD_LOCAL_FILE_ERROR, 13
  field :BES_STREAM_NOT_RETRYING_FAILURE, 14
  field :BES_STREAM_COMPLETED_WITH_UNACK_EVENTS_ERROR, 15
  field :BES_STREAM_COMPLETED_WITH_UNSENT_EVENTS_ERROR, 16
  field :BES_STREAM_COMPLETED_WITH_REMOTE_ERROR, 19
  field :BES_UPLOAD_RETRY_LIMIT_EXCEEDED_FAILURE, 17
end

defmodule FailureDetails.RemoteOptions.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.RemoteOptions.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :REMOTE_OPTIONS_UNKNOWN, 0
  field :REMOTE_DEFAULT_EXEC_PROPERTIES_LOGIC_ERROR, 1
  field :CREDENTIALS_READ_FAILURE, 2
  field :CREDENTIALS_WRITE_FAILURE, 3
  field :DOWNLOADER_WITHOUT_GRPC_CACHE, 4
  field :EXECUTION_WITH_INVALID_CACHE, 5
end

defmodule FailureDetails.ClientEnvironment.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ClientEnvironment.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CLIENT_ENVIRONMENT_UNKNOWN, 0
  field :CLIENT_CWD_MALFORMED, 1
end

defmodule FailureDetails.Crash.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Crash.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CRASH_UNKNOWN, 0
  field :CRASH_OOM, 1
end

defmodule FailureDetails.Crash.OomCauseCategory do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Crash.OomCauseCategory",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :NONE, 0
  field :ORGANIC, 1
  field :OOM_DETECTOR_OVERRIDE, 2
  field :GC_THRASHING, 3
  field :GC_CHURNING, 4
end

defmodule FailureDetails.SymlinkForest.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.SymlinkForest.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :SYMLINK_FOREST_UNKNOWN, 0
  field :TOPLEVEL_OUTDIR_PACKAGE_PATH_CONFLICT, 1
  field :TOPLEVEL_OUTDIR_USED_AS_SOURCE, 2
  field :CREATION_FAILED, 3
end

defmodule FailureDetails.BuildReport.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.BuildReport.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :BUILD_REPORT_UNKNOWN, 0
  field :BUILD_REPORT_UPLOADER_NEEDS_PACKAGE_PATHS, 1
  field :BUILD_REPORT_WRITE_FAILED, 2
end

defmodule FailureDetails.Skyfocus.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Skyfocus.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :INVALID_ACTIVE_DIRECTORIES, 0
  field :NON_ACTIVE_DIRECTORIES_CHANGE, 1
  field :CONFIGURATION_CHANGE, 2
  field :DISALLOWED_OPERATION_ON_FOCUSED_GRAPH, 3
end

defmodule FailureDetails.RemoteAnalysisCaching.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.RemoteAnalysisCaching.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :REMOTE_ANALYSIS_CACHING_UNKNOWN, 0
  field :SERIALIZED_FRONTIER_PROFILE_FAILED, 1
  field :PROJECT_FILE_NOT_FOUND, 2
  field :INCOMPATIBLE_OPTIONS, 3
  field :INVALID_SERVER_ADDRESS, 4
  field :CANNOT_OPEN_LOG_FILE, 5
end

defmodule FailureDetails.PackageOptions.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.PackageOptions.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PACKAGE_OPTIONS_UNKNOWN, 0
  field :PACKAGE_PATH_INVALID, 1
  field :NONSINGLETON_PACKAGE_PATH, 4
end

defmodule FailureDetails.RemoteExecution.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.RemoteExecution.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :REMOTE_EXECUTION_UNKNOWN, 0
  field :CAPABILITIES_QUERY_FAILURE, 1
  field :CREDENTIALS_INIT_FAILURE, 2
  field :CACHE_INIT_FAILURE, 3
  field :RPC_LOG_FAILURE, 4
  field :EXEC_CHANNEL_INIT_FAILURE, 5
  field :CACHE_CHANNEL_INIT_FAILURE, 6
  field :DOWNLOADER_CHANNEL_INIT_FAILURE, 7
  field :LOG_DIR_CLEANUP_FAILURE, 8
  field :CLIENT_SERVER_INCOMPATIBLE, 9
  field :DOWNLOADED_INPUTS_DELETION_FAILURE, 10
  field :REMOTE_DOWNLOAD_OUTPUTS_MINIMAL_WITHOUT_INMEMORY_DOTD, 11
  field :REMOTE_DOWNLOAD_OUTPUTS_MINIMAL_WITHOUT_INMEMORY_JDEPS, 12
  field :INCOMPLETE_OUTPUT_DOWNLOAD_CLEANUP_FAILURE, 13
  field :REMOTE_DEFAULT_PLATFORM_PROPERTIES_PARSE_FAILURE, 14
  field :ILLEGAL_OUTPUT, 15
  field :INVALID_EXEC_AND_PLATFORM_PROPERTIES, 16
  field :TOPLEVEL_OUTPUTS_DOWNLOAD_FAILURE, 17
end

defmodule FailureDetails.Execution.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Execution.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EXECUTION_UNKNOWN, 0
  field :EXECUTION_LOG_INITIALIZATION_FAILURE, 1
  field :EXECUTION_LOG_WRITE_FAILURE, 2
  field :EXECROOT_CREATION_FAILURE, 3
  field :TEMP_ACTION_OUTPUT_DIRECTORY_DELETION_FAILURE, 4
  field :TEMP_ACTION_OUTPUT_DIRECTORY_CREATION_FAILURE, 5
  field :PERSISTENT_ACTION_OUTPUT_DIRECTORY_CREATION_FAILURE, 6
  field :LOCAL_OUTPUT_DIRECTORY_SYMLINK_FAILURE, 7
  field :LOCAL_TEMPLATE_EXPANSION_FAILURE, 9
  field :INPUT_DIRECTORY_CHECK_IO_EXCEPTION, 10
  field :EXTRA_ACTION_OUTPUT_CREATION_FAILURE, 11
  field :TEST_RUNNER_IO_EXCEPTION, 12
  field :FILE_WRITE_IO_EXCEPTION, 13
  field :TEST_OUT_ERR_IO_EXCEPTION, 14
  field :SYMLINK_TREE_MANIFEST_COPY_IO_EXCEPTION, 15
  field :SYMLINK_TREE_MANIFEST_LINK_IO_EXCEPTION, 16
  field :SYMLINK_TREE_CREATION_IO_EXCEPTION, 17
  field :SYMLINK_TREE_CREATION_COMMAND_EXCEPTION, 18
  field :ACTION_INPUT_READ_IO_EXCEPTION, 19
  field :ACTION_NOT_UP_TO_DATE, 20
  field :PSEUDO_ACTION_EXECUTION_PROHIBITED, 21
  field :DISCOVERED_INPUT_DOES_NOT_EXIST, 22
  field :ACTION_OUTPUTS_DELETION_FAILURE, 23
  field :ACTION_OUTPUTS_NOT_CREATED, 24
  field :ACTION_FINALIZATION_FAILURE, 25
  field :ACTION_INPUT_LOST, 26
  field :FILESYSTEM_CONTEXT_UPDATE_FAILURE, 27
  field :ACTION_OUTPUT_CLOSE_FAILURE, 28
  field :INPUT_DISCOVERY_IO_EXCEPTION, 29
  field :TREE_ARTIFACT_DIRECTORY_CREATION_FAILURE, 30
  field :ACTION_OUTPUT_DIRECTORY_CREATION_FAILURE, 31
  field :ACTION_FS_OUTPUT_DIRECTORY_CREATION_FAILURE, 32
  field :ACTION_FS_OUT_ERR_DIRECTORY_CREATION_FAILURE, 33
  field :NON_ACTION_EXECUTION_FAILURE, 34
  field :CYCLE, 35
  field :SOURCE_INPUT_MISSING, 36
  field :UNEXPECTED_EXCEPTION, 37
  field :SOURCE_INPUT_IO_EXCEPTION, 39
  field :SYMLINK_TREE_DELETION_IO_EXCEPTION, 40
end

defmodule FailureDetails.Workspaces.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Workspaces.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :WORKSPACES_UNKNOWN, 0
  field :WORKSPACES_LOG_INITIALIZATION_FAILURE, 1
  field :WORKSPACES_LOG_WRITE_FAILURE, 2
  field :ILLEGAL_WORKSPACE_FILE_SYMLINK_WITH_MANAGED_DIRECTORIES, 3
  field :WORKSPACE_FILE_READ_FAILURE_WITH_MANAGED_DIRECTORIES, 4
end

defmodule FailureDetails.CrashOptions.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.CrashOptions.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CRASH_OPTIONS_UNKNOWN, 0
end

defmodule FailureDetails.Filesystem.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Filesystem.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :FILESYSTEM_UNKNOWN, 0
  field :EMBEDDED_BINARIES_ENUMERATION_FAILURE, 3
  field :SERVER_PID_TXT_FILE_READ_FAILURE, 4
  field :SERVER_FILE_WRITE_FAILURE, 5
  field :DEFAULT_DIGEST_HASH_FUNCTION_INVALID_VALUE, 6
  field :FILESYSTEM_JNI_NOT_AVAILABLE, 8
  field :FAILED_TO_LOCK_INSTALL_BASE, 12
  field :REMOTE_FILE_EVICTED, 13
end

defmodule FailureDetails.ExecutionOptions.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ExecutionOptions.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EXECUTION_OPTIONS_UNKNOWN, 0
  field :INVALID_STRATEGY, 3
  field :REQUESTED_STRATEGY_INCOMPATIBLE_WITH_SANDBOXING, 4
  field :DEPRECATED_LOCAL_RESOURCES_USED, 5
  field :INVALID_CYCLIC_DYNAMIC_STRATEGY, 6
  field :RESTRICTION_UNMATCHED_TO_ACTION_CONTEXT, 7
  field :REMOTE_FALLBACK_STRATEGY_NOT_ABSTRACT_SPAWN, 8
  field :STRATEGY_NOT_FOUND, 9
  field :DYNAMIC_STRATEGY_NOT_SANDBOXED, 10
  field :MULTIPLE_EXECUTION_LOG_FORMATS, 11
end

defmodule FailureDetails.Command.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Command.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :COMMAND_FAILURE_UNKNOWN, 0
  field :COMMAND_NOT_FOUND, 1
  field :ANOTHER_COMMAND_RUNNING, 2
  field :PREVIOUSLY_SHUTDOWN, 3
  field :STARLARK_CPU_PROFILE_FILE_INITIALIZATION_FAILURE, 4
  field :STARLARK_CPU_PROFILING_INITIALIZATION_FAILURE, 5
  field :STARLARK_CPU_PROFILE_FILE_WRITE_FAILURE, 6
  field :INVOCATION_POLICY_PARSE_FAILURE, 7
  field :INVOCATION_POLICY_INVALID, 8
  field :OPTIONS_PARSE_FAILURE, 9
  field :STARLARK_OPTIONS_PARSE_FAILURE, 10
  field :ARGUMENTS_NOT_RECOGNIZED, 11
  field :NOT_IN_WORKSPACE, 12
  field :IN_OUTPUT_DIRECTORY, 14
end

defmodule FailureDetails.GrpcServer.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.GrpcServer.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :GRPC_SERVER_UNKNOWN, 0
  field :GRPC_SERVER_NOT_COMPILED_IN, 1
  field :SERVER_BIND_FAILURE, 2
  field :BAD_COOKIE, 3
  field :NO_CLIENT_DESCRIPTION, 4
end

defmodule FailureDetails.CanonicalizeFlags.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.CanonicalizeFlags.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CANONICALIZE_FLAGS_UNKNOWN, 0
  field :FOR_COMMAND_INVALID, 1
end

defmodule FailureDetails.BuildConfiguration.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.BuildConfiguration.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :BUILD_CONFIGURATION_UNKNOWN, 0
  field :PLATFORM_MAPPING_EVALUATION_FAILURE, 1
  field :PLATFORM_MAPPINGS_FILE_IS_DIRECTORY, 2
  field :PLATFORM_MAPPINGS_FILE_NOT_FOUND, 3
  field :TOP_LEVEL_CONFIGURATION_CREATION_FAILURE, 4
  field :INVALID_CONFIGURATION, 5
  field :INVALID_BUILD_OPTIONS, 6
  field :MULTI_CPU_PREREQ_UNMET, 7
  field :HEURISTIC_INSTRUMENTATION_FILTER_INVALID, 8
  field :CYCLE, 9
  field :CONFLICTING_CONFIGURATIONS, 10
  field :INVALID_OUTPUT_DIRECTORY_MNEMONIC, 11
  field :CONFIGURATION_DISCARDED_ANALYSIS_CACHE, 12
  field :INVALID_PROJECT, 13
end

defmodule FailureDetails.InfoCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.InfoCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :INFO_COMMAND_UNKNOWN, 0
  field :TOO_MANY_KEYS, 1
  field :KEY_NOT_RECOGNIZED, 2
  field :INFO_BLOCK_WRITE_FAILURE, 3
  field :ALL_INFO_WRITE_FAILURE, 4
end

defmodule FailureDetails.MemoryOptions.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.MemoryOptions.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MEMORY_OPTIONS_UNKNOWN, 0
  field :DEPRECATED_EXPERIMENTAL_OOM_MORE_EAGERLY_THRESHOLD_INVALID_VALUE, 1
  field :DEPRECATED_EXPERIMENTAL_OOM_MORE_EAGERLY_NO_TENURED_COLLECTORS_FOUND, 2
end

defmodule FailureDetails.Query.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Query.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :QUERY_UNKNOWN, 0
  field :QUERY_FILE_WITH_COMMAND_LINE_EXPRESSION, 1
  field :QUERY_FILE_READ_FAILURE, 2
  field :COMMAND_LINE_EXPRESSION_MISSING, 3
  field :OUTPUT_FORMAT_INVALID, 4
  field :GRAPHLESS_PREREQ_UNMET, 5
  field :QUERY_OUTPUT_WRITE_FAILURE, 6
  field :QUERY_STDOUT_FLUSH_FAILURE, 13
  field :ANALYSIS_QUERY_PREREQ_UNMET, 14
  field :QUERY_RESULTS_FLUSH_FAILURE, 15
  field :DEPRECATED_UNCLOSED_QUOTATION_EXPRESSION_ERROR, 16
  field :VARIABLE_NAME_INVALID, 17
  field :VARIABLE_UNDEFINED, 18
  field :BUILDFILES_AND_LOADFILES_CANNOT_USE_OUTPUT_LOCATION_ERROR, 19
  field :BUILD_FILE_ERROR, 20
  field :CYCLE, 21
  field :UNIQUE_SKYKEY_THRESHOLD_EXCEEDED, 22
  field :TARGET_NOT_IN_UNIVERSE_SCOPE, 23
  field :INVALID_FULL_UNIVERSE_EXPRESSION, 24
  field :UNIVERSE_SCOPE_LIMIT_EXCEEDED, 25
  field :INVALIDATION_LIMIT_EXCEEDED, 26
  field :OUTPUT_FORMAT_PREREQ_UNMET, 27
  field :ARGUMENTS_MISSING, 28
  field :RBUILDFILES_FUNCTION_REQUIRES_SKYQUERY, 29
  field :FULL_TARGETS_NOT_SUPPORTED, 30
  field :DEPRECATED_UNEXPECTED_TOKEN_ERROR, 31
  field :DEPRECATED_INTEGER_LITERAL_MISSING, 32
  field :DEPRECATED_INVALID_STARTING_CHARACTER_ERROR, 33
  field :DEPRECATED_PREMATURE_END_OF_INPUT_ERROR, 34
  field :SYNTAX_ERROR, 35
  field :OUTPUT_FORMATTER_IO_EXCEPTION, 36
  field :SKYQUERY_TRANSITIVE_TARGET_ERROR, 37
  field :SKYQUERY_TARGET_EXCEPTION, 38
  field :INVALID_LABEL_IN_TEST_SUITE, 39
  field :ILLEGAL_FLAG_COMBINATION, 40
  field :NON_DETAILED_ERROR, 41
end

defmodule FailureDetails.LocalExecution.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.LocalExecution.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :LOCAL_EXECUTION_UNKNOWN, 0
  field :LOCKFREE_OUTPUT_PREREQ_UNMET, 1
  field :UNTRACKED_RESOURCE, 2
  field :NOT_ENOUGH_LOCAL_RESOURCE, 3
end

defmodule FailureDetails.ActionCache.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ActionCache.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ACTION_CACHE_UNKNOWN, 0
  field :INITIALIZATION_FAILURE, 1
end

defmodule FailureDetails.FetchCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.FetchCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :FETCH_COMMAND_UNKNOWN, 0
  field :EXPRESSION_MISSING, 1
  field :OPTIONS_INVALID, 2
  field :QUERY_PARSE_ERROR, 3
  field :QUERY_EVALUATION_ERROR, 4
end

defmodule FailureDetails.SyncCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.SyncCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :SYNC_COMMAND_UNKNOWN, 0
  field :PACKAGE_LOOKUP_ERROR, 1
  field :WORKSPACE_EVALUATION_ERROR, 2
  field :REPOSITORY_FETCH_ERRORS, 3
  field :REPOSITORY_NAME_INVALID, 4
end

defmodule FailureDetails.Sandbox.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Sandbox.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :SANDBOX_FAILURE_UNKNOWN, 0
  field :INITIALIZATION_FAILURE, 1
  field :EXECUTION_IO_EXCEPTION, 2
  field :DOCKER_COMMAND_FAILURE, 3
  field :NO_DOCKER_IMAGE, 4
  field :DOCKER_IMAGE_PREPARATION_FAILURE, 5
  field :BIND_MOUNT_ANALYSIS_FAILURE, 6
  field :MOUNT_SOURCE_DOES_NOT_EXIST, 7
  field :MOUNT_SOURCE_TARGET_TYPE_MISMATCH, 8
  field :MOUNT_TARGET_DOES_NOT_EXIST, 9
  field :SUBPROCESS_START_FAILED, 10
  field :FORBIDDEN_INPUT, 11
  field :COPY_INPUTS_IO_EXCEPTION, 12
  field :COPY_OUTPUTS_IO_EXCEPTION, 13
end

defmodule FailureDetails.IncludeScanning.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.IncludeScanning.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :INCLUDE_SCANNING_UNKNOWN, 0
  field :INITIALIZE_INCLUDE_HINTS_ERROR, 1
  field :SCANNING_IO_EXCEPTION, 2
  field :INCLUDE_HINTS_FILE_NOT_IN_PACKAGE, 3
  field :INCLUDE_HINTS_READ_FAILURE, 4
  field :ILLEGAL_ABSOLUTE_PATH, 5
  field :PACKAGE_LOAD_FAILURE, 6
  field :USER_PACKAGE_LOAD_FAILURE, 7
  field :SYSTEM_PACKAGE_LOAD_FAILURE, 8
  field :UNDIFFERENTIATED_PACKAGE_LOAD_FAILURE, 9
end

defmodule FailureDetails.TestCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.TestCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :TEST_COMMAND_UNKNOWN, 0
  field :NO_TEST_TARGETS, 1
  field :TEST_WITH_NOANALYZE, 2
  field :TESTS_FAILED, 3
end

defmodule FailureDetails.ActionQuery.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ActionQuery.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ACTION_QUERY_UNKNOWN, 0
  field :COMMAND_LINE_EXPANSION_FAILURE, 1
  field :OUTPUT_FAILURE, 2
  field :COMMAND_LINE_EXPRESSION_MISSING, 3
  field :EXPRESSION_PARSE_FAILURE, 4
  field :SKYFRAME_STATE_WITH_COMMAND_LINE_EXPRESSION, 5
  field :INVALID_AQUERY_EXPRESSION, 6
  field :SKYFRAME_STATE_PREREQ_UNMET, 7
  field :AQUERY_OUTPUT_TOO_BIG, 8
  field :ILLEGAL_PATTERN_SYNTAX, 9
  field :INCORRECT_ARGUMENTS, 10
  field :TOP_LEVEL_TARGETS_WITH_SKYFRAME_STATE_NOT_SUPPORTED, 11
  field :SKYFRAME_STATE_AFTER_EXECUTION, 12
  field :LABELS_FUNCTION_NOT_SUPPORTED, 13
  field :TEMPLATE_EXPANSION_FAILURE, 14
end

defmodule FailureDetails.TargetPatterns.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.TargetPatterns.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :TARGET_PATTERNS_UNKNOWN, 0
  field :TARGET_PATTERN_FILE_WITH_COMMAND_LINE_PATTERN, 1
  field :TARGET_PATTERN_FILE_READ_FAILURE, 2
  field :TARGET_PATTERN_PARSE_FAILURE, 3
  field :PACKAGE_NOT_FOUND, 4
  field :TARGET_FORMAT_INVALID, 5
  field :ABSOLUTE_TARGET_PATTERN_INVALID, 6
  field :CANNOT_DETERMINE_TARGET_FROM_FILENAME, 7
  field :LABEL_SYNTAX_ERROR, 8
  field :TARGET_CANNOT_BE_EMPTY_STRING, 9
  field :PACKAGE_PART_CANNOT_END_IN_SLASH, 10
  field :CYCLE, 11
  field :CANNOT_PRELOAD_TARGET, 12
  field :TARGETS_MISSING, 13
  field :RECURSIVE_TARGET_PATTERNS_NOT_ALLOWED, 14
  field :UP_LEVEL_REFERENCES_NOT_ALLOWED, 15
  field :NEGATIVE_TARGET_PATTERN_NOT_ALLOWED, 16
  field :TARGET_MUST_BE_A_FILE, 17
  field :DEPENDENCY_NOT_FOUND, 18
  field :PACKAGE_NAME_INVALID, 19
end

defmodule FailureDetails.CleanCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.CleanCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CLEAN_COMMAND_UNKNOWN, 0
  field :OUTPUT_SERVICE_CLEAN_FAILURE, 1
  field :ACTION_CACHE_CLEAN_FAILURE, 2
  field :OUT_ERR_CLOSE_FAILURE, 3
  field :OUTPUT_BASE_DELETE_FAILURE, 4
  field :OUTPUT_BASE_TEMP_MOVE_FAILURE, 5
  field :ASYNC_OUTPUT_BASE_DELETE_FAILURE, 6
  field :EXECROOT_DELETE_FAILURE, 7
  field :EXECROOT_TEMP_MOVE_FAILURE, 8
  field :ASYNC_EXECROOT_DELETE_FAILURE, 9
  field :ARGUMENTS_NOT_RECOGNIZED, 10
end

defmodule FailureDetails.ConfigCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ConfigCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CONFIG_COMMAND_UNKNOWN, 0
  field :TOO_MANY_CONFIG_IDS, 1
  field :CONFIGURATION_NOT_FOUND, 2
end

defmodule FailureDetails.ConfigurableQuery.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ConfigurableQuery.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CONFIGURABLE_QUERY_UNKNOWN, 0
  field :COMMAND_LINE_EXPRESSION_MISSING, 1
  field :EXPRESSION_PARSE_FAILURE, 2
  field :FILTERS_NOT_SUPPORTED, 3
  field :BUILDFILES_FUNCTION_NOT_SUPPORTED, 4
  field :SIBLINGS_FUNCTION_NOT_SUPPORTED, 5
  field :VISIBLE_FUNCTION_NOT_SUPPORTED, 6
  field :ATTRIBUTE_MISSING, 7
  field :INCORRECT_CONFIG_ARGUMENT_ERROR, 8
  field :TARGET_MISSING, 9
  field :STARLARK_SYNTAX_ERROR, 10
  field :STARLARK_EVAL_ERROR, 11
  field :FORMAT_FUNCTION_ERROR, 12
end

defmodule FailureDetails.DumpCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.DumpCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :DUMP_COMMAND_UNKNOWN, 0
  field :NO_OUTPUT_SPECIFIED, 1
  field :ACTION_CACHE_DUMP_FAILED, 2
  field :COMMAND_LINE_EXPANSION_FAILURE, 3
  field :ACTION_GRAPH_DUMP_FAILED, 4
  field :STARLARK_HEAP_DUMP_FAILED, 5
  field :SKYFRAME_MEMORY_DUMP_FAILED, 7
end

defmodule FailureDetails.HelpCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.HelpCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :HELP_COMMAND_UNKNOWN, 0
  field :MISSING_ARGUMENT, 1
  field :COMMAND_NOT_FOUND, 2
end

defmodule FailureDetails.MobileInstall.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.MobileInstall.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MOBILE_INSTALL_UNKNOWN, 0
  field :CLASSIC_UNSUPPORTED, 1
  field :NO_TARGET_SPECIFIED, 2
  field :MULTIPLE_TARGETS_SPECIFIED, 3
  field :TARGET_TYPE_INVALID, 4
  field :NON_ZERO_EXIT, 5
  field :ERROR_RUNNING_PROGRAM, 6
end

defmodule FailureDetails.ProfileCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ProfileCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PROFILE_COMMAND_UNKNOWN, 0
  field :OLD_BINARY_FORMAT_UNSUPPORTED, 1
  field :FILE_READ_FAILURE, 2
end

defmodule FailureDetails.RunCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.RunCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :RUN_COMMAND_UNKNOWN, 0
  field :NO_TARGET_SPECIFIED, 1
  field :TOO_MANY_TARGETS_SPECIFIED, 2
  field :TARGET_NOT_EXECUTABLE, 3
  field :TARGET_BUILT_BUT_PATH_NOT_EXECUTABLE, 4
  field :TARGET_BUILT_BUT_PATH_VALIDATION_FAILED, 5
  field :RUN_UNDER_TARGET_NOT_BUILT, 6
  field :RUN_PREREQ_UNMET, 7
  field :TOO_MANY_TEST_SHARDS_OR_RUNS, 8
  field :TEST_ENVIRONMENT_SETUP_FAILURE, 9
  field :COMMAND_LINE_EXPANSION_FAILURE, 10
  field :NO_SHELL_SPECIFIED, 11
  field :SCRIPT_WRITE_FAILURE, 12
  field :RUNFILES_DIRECTORIES_CREATION_FAILURE, 13
  field :RUNFILES_SYMLINKS_CREATION_FAILURE, 14
  field :TEST_ENVIRONMENT_SETUP_INTERRUPTED, 15
end

defmodule FailureDetails.VersionCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.VersionCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :VERSION_COMMAND_UNKNOWN, 0
  field :NOT_AVAILABLE, 1
end

defmodule FailureDetails.PrintActionCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.PrintActionCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PRINT_ACTION_COMMAND_UNKNOWN, 0
  field :TARGET_NOT_FOUND, 1
  field :COMMAND_LINE_EXPANSION_FAILURE, 2
  field :TARGET_KIND_UNSUPPORTED, 3
  field :ACTIONS_NOT_FOUND, 4
end

defmodule FailureDetails.WorkspaceStatus.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.WorkspaceStatus.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :WORKSPACE_STATUS_UNKNOWN, 0
  field :NON_ZERO_EXIT, 1
  field :ABNORMAL_TERMINATION, 2
  field :EXEC_FAILED, 3
  field :PARSE_FAILURE, 4
  field :VALIDATION_FAILURE, 5
  field :CONTENT_UPDATE_IO_EXCEPTION, 6
  field :STDERR_IO_EXCEPTION, 7
end

defmodule FailureDetails.JavaCompile.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.JavaCompile.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :JAVA_COMPILE_UNKNOWN, 0
  field :REDUCED_CLASSPATH_FAILURE, 1
  field :COMMAND_LINE_EXPANSION_FAILURE, 2
  field :JDEPS_READ_IO_EXCEPTION, 3
  field :REDUCED_CLASSPATH_FALLBACK_CLEANUP_FAILURE, 4
end

defmodule FailureDetails.ActionRewinding.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ActionRewinding.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ACTION_REWINDING_UNKNOWN, 0
  field :LOST_INPUT_TOO_MANY_TIMES, 1
  field :REWIND_LOST_INPUTS_PREREQ_UNMET, 3
  field :LOST_OUTPUT_TOO_MANY_TIMES, 4
  field :LOST_INPUT_REWINDING_DISABLED, 5
  field :LOST_OUTPUT_REWINDING_DISABLED, 6
  field :DEPRECATED_LOST_INPUT_IS_SOURCE, 2
end

defmodule FailureDetails.CppCompile.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.CppCompile.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CPP_COMPILE_UNKNOWN, 0
  field :FIND_USED_HEADERS_IO_EXCEPTION, 1
  field :COPY_OUT_ERR_FAILURE, 2
  field :D_FILE_READ_FAILURE, 3
  field :COMMAND_GENERATION_FAILURE, 4
  field :MODULE_EXPANSION_TIMEOUT, 5
  field :INCLUDE_PATH_OUTSIDE_EXEC_ROOT, 6
  field :FAKE_COMMAND_GENERATION_FAILURE, 7
  field :UNDECLARED_INCLUSIONS, 8
  field :D_FILE_PARSE_FAILURE, 9
  field :COVERAGE_NOTES_CREATION_FAILURE, 10
  field :MODULE_EXPANSION_MISSING_DATA, 11
  field :MODMAP_INPUT_FILE_READ_FAILURE, 12
end

defmodule FailureDetails.StarlarkAction.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.StarlarkAction.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :STARLARK_ACTION_UNKNOWN, 0
  field :UNUSED_INPUT_LIST_READ_FAILURE, 1
  field :UNUSED_INPUT_LIST_FILE_NOT_FOUND, 2
end

defmodule FailureDetails.NinjaAction.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.NinjaAction.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :NINJA_ACTION_UNKNOWN, 0
  field :INVALID_DEPFILE_DECLARED_DEPENDENCY, 1
  field :D_FILE_PARSE_FAILURE, 2
end

defmodule FailureDetails.DynamicExecution.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.DynamicExecution.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :DYNAMIC_EXECUTION_UNKNOWN, 0
  field :XCODE_RELATED_PREREQ_UNMET, 1
  field :ACTION_LOG_MOVE_FAILURE, 2
  field :RUN_FAILURE, 3
  field :NO_USABLE_STRATEGY_FOUND, 4
end

defmodule FailureDetails.FailAction.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.FailAction.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :FAIL_ACTION_UNKNOWN, 0
  field :INTENTIONAL_FAILURE, 1
  field :INCORRECT_PYTHON_VERSION, 2
  field :PROGUARD_SPECS_MISSING, 3
  field :DYNAMIC_LINKING_NOT_SUPPORTED, 4
  field :SOURCE_FILES_MISSING, 5
  field :INCORRECT_TOOLCHAIN, 6
  field :FRAGMENT_CLASS_MISSING, 7
  field :CANT_BUILD_INCOMPATIBLE_TARGET, 10
end

defmodule FailureDetails.SymlinkAction.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.SymlinkAction.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :SYMLINK_ACTION_UNKNOWN, 0
  field :EXECUTABLE_INPUT_NOT_FILE, 1
  field :EXECUTABLE_INPUT_IS_NOT, 2
  field :EXECUTABLE_INPUT_CHECK_IO_EXCEPTION, 3
  field :LINK_CREATION_IO_EXCEPTION, 4
  field :LINK_TOUCH_IO_EXCEPTION, 5
  field :LINK_LOG_IO_EXCEPTION, 6
end

defmodule FailureDetails.CppLink.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.CppLink.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CPP_LINK_UNKNOWN, 0
  field :COMMAND_GENERATION_FAILURE, 1
  field :FAKE_COMMAND_GENERATION_FAILURE, 2
end

defmodule FailureDetails.LtoAction.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.LtoAction.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :LTO_ACTION_UNKNOWN, 0
  field :INVALID_ABSOLUTE_PATH_IN_IMPORTS, 1
  field :MISSING_BITCODE_FILES, 2
  field :IMPORTS_READ_IO_EXCEPTION, 3
end

defmodule FailureDetails.TestAction.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.TestAction.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :TEST_ACTION_UNKNOWN, 0
  field :NO_KEEP_GOING_TEST_FAILURE, 1
  field :LOCAL_TEST_PREREQ_UNMET, 2
  field :COMMAND_LINE_EXPANSION_FAILURE, 3
  field :DUPLICATE_CPU_TAGS, 4
  field :INVALID_CPU_TAG, 5
end

defmodule FailureDetails.Worker.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Worker.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :WORKER_UNKNOWN, 0
  field :MULTIPLEXER_INSTANCE_REMOVAL_FAILURE, 1
  field :MULTIPLEXER_DOES_NOT_EXIST, 2
  field :NO_TOOLS, 3
  field :NO_FLAGFILE, 4
  field :VIRTUAL_INPUT_MATERIALIZATION_FAILURE, 5
  field :BORROW_FAILURE, 6
  field :PREFETCH_FAILURE, 7
  field :PREPARE_FAILURE, 8
  field :REQUEST_FAILURE, 9
  field :PARSE_RESPONSE_FAILURE, 10
  field :NO_RESPONSE, 11
  field :FINISH_FAILURE, 12
  field :FORBIDDEN_INPUT, 13
end

defmodule FailureDetails.Analysis.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Analysis.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ANALYSIS_UNKNOWN, 0
  field :LOAD_FAILURE, 1
  field :GENERIC_LOADING_PHASE_FAILURE, 2
  field :NOT_ALL_TARGETS_ANALYZED, 3
  field :CYCLE, 4
  field :PARAMETERIZED_TOP_LEVEL_ASPECT_INVALID, 5
  field :ASPECT_LABEL_SYNTAX_ERROR, 6
  field :ASPECT_PREREQ_UNMET, 7
  field :ASPECT_NOT_FOUND, 8
  field :ACTION_CONFLICT, 9
  field :ARTIFACT_PREFIX_CONFLICT, 10
  field :UNEXPECTED_ANALYSIS_EXCEPTION, 11
  field :TARGETS_MISSING_ENVIRONMENTS, 12
  field :INVALID_ENVIRONMENT, 13
  field :ENVIRONMENT_MISSING_FROM_GROUPS, 14
  field :EXEC_GROUP_MISSING, 15
  field :INVALID_EXECUTION_PLATFORM, 16
  field :ASPECT_CREATION_FAILED, 17
  field :CONFIGURED_VALUE_CREATION_FAILED, 18
  field :INCOMPATIBLE_TARGET_REQUESTED, 19
  field :ANALYSIS_FAILURE_PROPAGATION_FAILED, 20
  field :ANALYSIS_CACHE_DISCARDED, 21
  field :INVALID_RUNFILES_TREE, 22
end

defmodule FailureDetails.PackageLoading.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.PackageLoading.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PACKAGE_LOADING_UNKNOWN, 0
  field :WORKSPACE_FILE_ERROR, 1
  field :MAX_COMPUTATION_STEPS_EXCEEDED, 2
  field :BUILD_FILE_MISSING, 3
  field :REPOSITORY_MISSING, 4
  field :PERSISTENT_INCONSISTENT_FILESYSTEM_ERROR, 5
  field :TRANSIENT_INCONSISTENT_FILESYSTEM_ERROR, 6
  field :INVALID_NAME, 7
  field :EVAL_GLOBS_SYMLINK_ERROR, 9
  field :IMPORT_STARLARK_FILE_ERROR, 10
  field :PACKAGE_MISSING, 11
  field :TARGET_MISSING, 12
  field :NO_SUCH_THING, 13
  field :GLOB_IO_EXCEPTION, 14
  field :DUPLICATE_LABEL, 15
  field :INVALID_PACKAGE_SPECIFICATION, 16
  field :SYNTAX_ERROR, 17
  field :ENVIRONMENT_IN_DIFFERENT_PACKAGE, 18
  field :DEFAULT_ENVIRONMENT_UNDECLARED, 19
  field :ENVIRONMENT_IN_MULTIPLE_GROUPS, 20
  field :ENVIRONMENT_DOES_NOT_EXIST, 21
  field :ENVIRONMENT_INVALID, 22
  field :ENVIRONMENT_NOT_IN_GROUP, 23
  field :PACKAGE_NAME_INVALID, 24
  field :STARLARK_EVAL_ERROR, 25
  field :LICENSE_PARSE_FAILURE, 26
  field :DISTRIBUTIONS_PARSE_FAILURE, 27
  field :LABEL_CROSSES_PACKAGE_BOUNDARY, 28
  field :BUILTINS_INJECTION_FAILURE, 29
  field :SYMLINK_CYCLE_OR_INFINITE_EXPANSION, 30
  field :OTHER_IO_EXCEPTION, 31
  field :BAD_REPO_FILE, 32
  field :BAD_IGNORED_DIRECTORIES, 33
end

defmodule FailureDetails.Toolchain.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.Toolchain.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :TOOLCHAIN_UNKNOWN, 0
  field :MISSING_PROVIDER, 1
  field :INVALID_CONSTRAINT_VALUE, 2
  field :INVALID_PLATFORM_VALUE, 3
  field :INVALID_TOOLCHAIN, 4
  field :NO_MATCHING_EXECUTION_PLATFORM, 5
  field :NO_MATCHING_TOOLCHAIN, 6
  field :INVALID_TOOLCHAIN_TYPE, 7
end

defmodule FailureDetails.StarlarkLoading.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.StarlarkLoading.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :STARLARK_LOADING_UNKNOWN, 0
  field :CYCLE, 1
  field :COMPILE_ERROR, 2
  field :PARSE_ERROR, 3
  field :EVAL_ERROR, 4
  field :CONTAINING_PACKAGE_NOT_FOUND, 5
  field :PACKAGE_NOT_FOUND, 6
  field :IO_ERROR, 7
  field :LABEL_CROSSES_PACKAGE_BOUNDARY, 8
  field :BUILTINS_ERROR, 9
  field :VISIBILITY_ERROR, 10
end

defmodule FailureDetails.ExternalDeps.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ExternalDeps.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :EXTERNAL_DEPS_UNKNOWN, 0
  field :MODULE_NOT_FOUND, 1
  field :BAD_MODULE, 2
  field :VERSION_RESOLUTION_ERROR, 3
  field :INVALID_REGISTRY_URL, 4
  field :ERROR_ACCESSING_REGISTRY, 5
  field :INVALID_EXTENSION_IMPORT, 6
  field :BAD_LOCKFILE, 7
  field :EXTENSION_EVAL_ERROR, 8
end

defmodule FailureDetails.DiffAwareness.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.DiffAwareness.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :DIFF_AWARENESS_UNKNOWN, 0
  field :DIFF_STAT_FAILED, 1
end

defmodule FailureDetails.ModCommand.Code do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "failure_details.ModCommand.Code",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MOD_COMMAND_UNKNOWN, 0
  field :MISSING_ARGUMENTS, 1
  field :TOO_MANY_ARGUMENTS, 2
  field :INVALID_ARGUMENTS, 3
  field :BUILDOZER_FAILED, 4
  field :ERROR_DURING_GRAPH_INSPECTION, 5
end

defmodule FailureDetails.FailureDetailMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.FailureDetailMetadata",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :exit_code, 1, type: :uint32, json_name: "exitCode"
end

defmodule FailureDetails.FailureDetail do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.FailureDetail",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:category, 0)

  field :message, 1, type: :string
  field :interrupted, 101, type: FailureDetails.Interrupted, oneof: 0

  field :external_repository, 103,
    type: FailureDetails.ExternalRepository,
    json_name: "externalRepository",
    oneof: 0

  field :build_progress, 104,
    type: FailureDetails.BuildProgress,
    json_name: "buildProgress",
    oneof: 0

  field :remote_options, 106,
    type: FailureDetails.RemoteOptions,
    json_name: "remoteOptions",
    oneof: 0

  field :client_environment, 107,
    type: FailureDetails.ClientEnvironment,
    json_name: "clientEnvironment",
    oneof: 0

  field :crash, 108, type: FailureDetails.Crash, oneof: 0

  field :symlink_forest, 110,
    type: FailureDetails.SymlinkForest,
    json_name: "symlinkForest",
    oneof: 0

  field :package_options, 114,
    type: FailureDetails.PackageOptions,
    json_name: "packageOptions",
    oneof: 0

  field :remote_execution, 115,
    type: FailureDetails.RemoteExecution,
    json_name: "remoteExecution",
    oneof: 0

  field :execution, 116, type: FailureDetails.Execution, oneof: 0
  field :workspaces, 117, type: FailureDetails.Workspaces, oneof: 0

  field :crash_options, 118,
    type: FailureDetails.CrashOptions,
    json_name: "crashOptions",
    oneof: 0

  field :filesystem, 119, type: FailureDetails.Filesystem, oneof: 0

  field :execution_options, 121,
    type: FailureDetails.ExecutionOptions,
    json_name: "executionOptions",
    oneof: 0

  field :command, 122, type: FailureDetails.Command, oneof: 0
  field :spawn, 123, type: FailureDetails.Spawn, oneof: 0
  field :grpc_server, 124, type: FailureDetails.GrpcServer, json_name: "grpcServer", oneof: 0

  field :canonicalize_flags, 125,
    type: FailureDetails.CanonicalizeFlags,
    json_name: "canonicalizeFlags",
    oneof: 0

  field :build_configuration, 126,
    type: FailureDetails.BuildConfiguration,
    json_name: "buildConfiguration",
    oneof: 0

  field :info_command, 127, type: FailureDetails.InfoCommand, json_name: "infoCommand", oneof: 0

  field :memory_options, 129,
    type: FailureDetails.MemoryOptions,
    json_name: "memoryOptions",
    oneof: 0

  field :query, 130, type: FailureDetails.Query, oneof: 0

  field :local_execution, 132,
    type: FailureDetails.LocalExecution,
    json_name: "localExecution",
    oneof: 0

  field :action_cache, 134, type: FailureDetails.ActionCache, json_name: "actionCache", oneof: 0

  field :fetch_command, 135,
    type: FailureDetails.FetchCommand,
    json_name: "fetchCommand",
    oneof: 0

  field :sync_command, 136, type: FailureDetails.SyncCommand, json_name: "syncCommand", oneof: 0
  field :sandbox, 137, type: FailureDetails.Sandbox, oneof: 0

  field :include_scanning, 139,
    type: FailureDetails.IncludeScanning,
    json_name: "includeScanning",
    oneof: 0

  field :test_command, 140, type: FailureDetails.TestCommand, json_name: "testCommand", oneof: 0
  field :action_query, 141, type: FailureDetails.ActionQuery, json_name: "actionQuery", oneof: 0

  field :target_patterns, 142,
    type: FailureDetails.TargetPatterns,
    json_name: "targetPatterns",
    oneof: 0

  field :clean_command, 144,
    type: FailureDetails.CleanCommand,
    json_name: "cleanCommand",
    oneof: 0

  field :config_command, 145,
    type: FailureDetails.ConfigCommand,
    json_name: "configCommand",
    oneof: 0

  field :configurable_query, 146,
    type: FailureDetails.ConfigurableQuery,
    json_name: "configurableQuery",
    oneof: 0

  field :dump_command, 147, type: FailureDetails.DumpCommand, json_name: "dumpCommand", oneof: 0
  field :help_command, 148, type: FailureDetails.HelpCommand, json_name: "helpCommand", oneof: 0

  field :mobile_install, 150,
    type: FailureDetails.MobileInstall,
    json_name: "mobileInstall",
    oneof: 0

  field :profile_command, 151,
    type: FailureDetails.ProfileCommand,
    json_name: "profileCommand",
    oneof: 0

  field :run_command, 152, type: FailureDetails.RunCommand, json_name: "runCommand", oneof: 0

  field :version_command, 153,
    type: FailureDetails.VersionCommand,
    json_name: "versionCommand",
    oneof: 0

  field :print_action_command, 154,
    type: FailureDetails.PrintActionCommand,
    json_name: "printActionCommand",
    oneof: 0

  field :workspace_status, 158,
    type: FailureDetails.WorkspaceStatus,
    json_name: "workspaceStatus",
    oneof: 0

  field :java_compile, 159, type: FailureDetails.JavaCompile, json_name: "javaCompile", oneof: 0

  field :action_rewinding, 160,
    type: FailureDetails.ActionRewinding,
    json_name: "actionRewinding",
    oneof: 0

  field :cpp_compile, 161, type: FailureDetails.CppCompile, json_name: "cppCompile", oneof: 0

  field :starlark_action, 162,
    type: FailureDetails.StarlarkAction,
    json_name: "starlarkAction",
    oneof: 0

  field :ninja_action, 163, type: FailureDetails.NinjaAction, json_name: "ninjaAction", oneof: 0

  field :dynamic_execution, 164,
    type: FailureDetails.DynamicExecution,
    json_name: "dynamicExecution",
    oneof: 0

  field :fail_action, 166, type: FailureDetails.FailAction, json_name: "failAction", oneof: 0

  field :symlink_action, 167,
    type: FailureDetails.SymlinkAction,
    json_name: "symlinkAction",
    oneof: 0

  field :cpp_link, 168, type: FailureDetails.CppLink, json_name: "cppLink", oneof: 0
  field :lto_action, 169, type: FailureDetails.LtoAction, json_name: "ltoAction", oneof: 0
  field :test_action, 172, type: FailureDetails.TestAction, json_name: "testAction", oneof: 0
  field :worker, 173, type: FailureDetails.Worker, oneof: 0
  field :analysis, 174, type: FailureDetails.Analysis, oneof: 0

  field :package_loading, 175,
    type: FailureDetails.PackageLoading,
    json_name: "packageLoading",
    oneof: 0

  field :toolchain, 177, type: FailureDetails.Toolchain, oneof: 0

  field :starlark_loading, 179,
    type: FailureDetails.StarlarkLoading,
    json_name: "starlarkLoading",
    oneof: 0

  field :external_deps, 181,
    type: FailureDetails.ExternalDeps,
    json_name: "externalDeps",
    oneof: 0

  field :diff_awareness, 182,
    type: FailureDetails.DiffAwareness,
    json_name: "diffAwareness",
    oneof: 0

  field :mod_command, 183, type: FailureDetails.ModCommand, json_name: "modCommand", oneof: 0
  field :build_report, 184, type: FailureDetails.BuildReport, json_name: "buildReport", oneof: 0
  field :skyfocus, 185, type: FailureDetails.Skyfocus, oneof: 0

  field :remote_analysis_caching, 186,
    type: FailureDetails.RemoteAnalysisCaching,
    json_name: "remoteAnalysisCaching",
    oneof: 0
end

defmodule FailureDetails.Interrupted do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Interrupted",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Interrupted.Code, enum: true
end

defmodule FailureDetails.Spawn do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Spawn",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Spawn.Code, enum: true
  field :catastrophic, 2, type: :bool
  field :spawn_exit_code, 3, type: :int32, json_name: "spawnExitCode"
end

defmodule FailureDetails.ExternalRepository do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ExternalRepository",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ExternalRepository.Code, enum: true
end

defmodule FailureDetails.BuildProgress do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.BuildProgress",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.BuildProgress.Code, enum: true
end

defmodule FailureDetails.RemoteOptions do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.RemoteOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.RemoteOptions.Code, enum: true
end

defmodule FailureDetails.ClientEnvironment do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ClientEnvironment",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ClientEnvironment.Code, enum: true
end

defmodule FailureDetails.Crash do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Crash",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Crash.Code, enum: true
  field :causes, 2, repeated: true, type: FailureDetails.Throwable

  field :oom_cause_category, 4,
    type: FailureDetails.Crash.OomCauseCategory,
    json_name: "oomCauseCategory",
    enum: true
end

defmodule FailureDetails.Throwable do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Throwable",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :throwable_class, 1, type: :string, json_name: "throwableClass"
  field :message, 2, type: :string
  field :stack_trace, 3, repeated: true, type: :string, json_name: "stackTrace"
end

defmodule FailureDetails.SymlinkForest do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.SymlinkForest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.SymlinkForest.Code, enum: true
end

defmodule FailureDetails.BuildReport do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.BuildReport",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.BuildReport.Code, enum: true
end

defmodule FailureDetails.Skyfocus do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Skyfocus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Skyfocus.Code, enum: true
end

defmodule FailureDetails.RemoteAnalysisCaching do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.RemoteAnalysisCaching",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.RemoteAnalysisCaching.Code, enum: true
end

defmodule FailureDetails.PackageOptions do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.PackageOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.PackageOptions.Code, enum: true
end

defmodule FailureDetails.RemoteExecution do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.RemoteExecution",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.RemoteExecution.Code, enum: true
end

defmodule FailureDetails.Execution do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Execution",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Execution.Code, enum: true
end

defmodule FailureDetails.Workspaces do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Workspaces",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Workspaces.Code, enum: true
end

defmodule FailureDetails.CrashOptions do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.CrashOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.CrashOptions.Code, enum: true
end

defmodule FailureDetails.Filesystem do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Filesystem",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Filesystem.Code, enum: true
end

defmodule FailureDetails.ExecutionOptions do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ExecutionOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ExecutionOptions.Code, enum: true
end

defmodule FailureDetails.Command do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Command",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Command.Code, enum: true
end

defmodule FailureDetails.GrpcServer do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.GrpcServer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.GrpcServer.Code, enum: true
end

defmodule FailureDetails.CanonicalizeFlags do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.CanonicalizeFlags",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.CanonicalizeFlags.Code, enum: true
end

defmodule FailureDetails.BuildConfiguration do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.BuildConfiguration",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.BuildConfiguration.Code, enum: true
end

defmodule FailureDetails.InfoCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.InfoCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.InfoCommand.Code, enum: true
end

defmodule FailureDetails.MemoryOptions do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.MemoryOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.MemoryOptions.Code, enum: true
end

defmodule FailureDetails.Query do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Query",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Query.Code, enum: true
end

defmodule FailureDetails.LocalExecution do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.LocalExecution",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.LocalExecution.Code, enum: true
end

defmodule FailureDetails.ActionCache do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ActionCache",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ActionCache.Code, enum: true
end

defmodule FailureDetails.FetchCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.FetchCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.FetchCommand.Code, enum: true
end

defmodule FailureDetails.SyncCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.SyncCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.SyncCommand.Code, enum: true
end

defmodule FailureDetails.Sandbox do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Sandbox",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Sandbox.Code, enum: true
end

defmodule FailureDetails.IncludeScanning do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.IncludeScanning",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.IncludeScanning.Code, enum: true

  field :package_loading_code, 2,
    type: FailureDetails.PackageLoading.Code,
    json_name: "packageLoadingCode",
    enum: true
end

defmodule FailureDetails.TestCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.TestCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.TestCommand.Code, enum: true
end

defmodule FailureDetails.ActionQuery do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ActionQuery",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ActionQuery.Code, enum: true
end

defmodule FailureDetails.TargetPatterns do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.TargetPatterns",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.TargetPatterns.Code, enum: true
end

defmodule FailureDetails.CleanCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.CleanCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.CleanCommand.Code, enum: true
end

defmodule FailureDetails.ConfigCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ConfigCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ConfigCommand.Code, enum: true
end

defmodule FailureDetails.ConfigurableQuery do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ConfigurableQuery",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ConfigurableQuery.Code, enum: true
end

defmodule FailureDetails.DumpCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.DumpCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.DumpCommand.Code, enum: true
end

defmodule FailureDetails.HelpCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.HelpCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.HelpCommand.Code, enum: true
end

defmodule FailureDetails.MobileInstall do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.MobileInstall",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.MobileInstall.Code, enum: true
end

defmodule FailureDetails.ProfileCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ProfileCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ProfileCommand.Code, enum: true
end

defmodule FailureDetails.RunCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.RunCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.RunCommand.Code, enum: true
end

defmodule FailureDetails.VersionCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.VersionCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.VersionCommand.Code, enum: true
end

defmodule FailureDetails.PrintActionCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.PrintActionCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.PrintActionCommand.Code, enum: true
end

defmodule FailureDetails.WorkspaceStatus do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.WorkspaceStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.WorkspaceStatus.Code, enum: true
end

defmodule FailureDetails.JavaCompile do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.JavaCompile",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.JavaCompile.Code, enum: true
end

defmodule FailureDetails.ActionRewinding do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ActionRewinding",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ActionRewinding.Code, enum: true
end

defmodule FailureDetails.CppCompile do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.CppCompile",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.CppCompile.Code, enum: true
end

defmodule FailureDetails.StarlarkAction do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.StarlarkAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.StarlarkAction.Code, enum: true
end

defmodule FailureDetails.NinjaAction do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.NinjaAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.NinjaAction.Code, enum: true
end

defmodule FailureDetails.DynamicExecution do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.DynamicExecution",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.DynamicExecution.Code, enum: true
end

defmodule FailureDetails.FailAction do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.FailAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.FailAction.Code, enum: true
end

defmodule FailureDetails.SymlinkAction do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.SymlinkAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.SymlinkAction.Code, enum: true
end

defmodule FailureDetails.CppLink do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.CppLink",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.CppLink.Code, enum: true
end

defmodule FailureDetails.LtoAction do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.LtoAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.LtoAction.Code, enum: true
end

defmodule FailureDetails.TestAction do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.TestAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.TestAction.Code, enum: true
end

defmodule FailureDetails.Worker do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Worker",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Worker.Code, enum: true
end

defmodule FailureDetails.Analysis do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Analysis",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Analysis.Code, enum: true
end

defmodule FailureDetails.PackageLoading do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.PackageLoading",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.PackageLoading.Code, enum: true
end

defmodule FailureDetails.Toolchain do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.Toolchain",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.Toolchain.Code, enum: true
end

defmodule FailureDetails.StarlarkLoading do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.StarlarkLoading",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.StarlarkLoading.Code, enum: true
end

defmodule FailureDetails.ExternalDeps do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ExternalDeps",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ExternalDeps.Code, enum: true
end

defmodule FailureDetails.DiffAwareness do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.DiffAwareness",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.DiffAwareness.Code, enum: true
end

defmodule FailureDetails.ModCommand do
  @moduledoc false

  use Protobuf,
    full_name: "failure_details.ModCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :code, 1, type: FailureDetails.ModCommand.Code, enum: true
end
