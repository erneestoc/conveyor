defmodule Build.Bazel.Remote.Execution.V2.Command.OutputDirectoryFormat do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build.bazel.remote.execution.v2.Command.OutputDirectoryFormat",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :TREE_ONLY, 0
  field :DIRECTORY_ONLY, 1
  field :TREE_AND_DIRECTORY, 2
end

defmodule Build.Bazel.Remote.Execution.V2.ExecutionStage.Value do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build.bazel.remote.execution.v2.ExecutionStage.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :CACHE_CHECK, 1
  field :QUEUED, 2
  field :EXECUTING, 3
  field :COMPLETED, 4
end

defmodule Build.Bazel.Remote.Execution.V2.DigestFunction.Value do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build.bazel.remote.execution.v2.DigestFunction.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :SHA256, 1
  field :SHA1, 2
  field :MD5, 3
  field :VSO, 4
  field :SHA384, 5
  field :SHA512, 6
  field :MURMUR3, 7
  field :SHA256TREE, 8
  field :BLAKE3, 9
  field :GITSHA1, 10
end

defmodule Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build.bazel.remote.execution.v2.ChunkingFunction.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :FAST_CDC_2020, 1
  field :REP_MAX_CDC, 2
end

defmodule Build.Bazel.Remote.Execution.V2.SymlinkAbsolutePathStrategy.Value do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build.bazel.remote.execution.v2.SymlinkAbsolutePathStrategy.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :DISALLOWED, 1
  field :ALLOWED, 2
end

defmodule Build.Bazel.Remote.Execution.V2.Compressor.Value do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "build.bazel.remote.execution.v2.Compressor.Value",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :IDENTITY, 0
  field :ZSTD, 1
  field :DEFLATE, 2
  field :BROTLI, 3
end

defmodule Build.Bazel.Remote.Execution.V2.Action do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Action",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :command_digest, 1,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "commandDigest"

  field :input_root_digest, 2,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "inputRootDigest"

  field :timeout, 6, type: Google.Protobuf.Duration
  field :do_not_cache, 7, type: :bool, json_name: "doNotCache"
  field :salt, 9, type: :bytes
  field :platform, 10, type: Build.Bazel.Remote.Execution.V2.Platform
end

defmodule Build.Bazel.Remote.Execution.V2.Command.EnvironmentVariable do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Command.EnvironmentVariable",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end

defmodule Build.Bazel.Remote.Execution.V2.Command do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Command",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :arguments, 1, repeated: true, type: :string

  field :environment_variables, 2,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Command.EnvironmentVariable,
    json_name: "environmentVariables"

  field :output_files, 3,
    repeated: true,
    type: :string,
    json_name: "outputFiles",
    deprecated: true

  field :output_directories, 4,
    repeated: true,
    type: :string,
    json_name: "outputDirectories",
    deprecated: true

  field :output_paths, 7, repeated: true, type: :string, json_name: "outputPaths"
  field :platform, 5, type: Build.Bazel.Remote.Execution.V2.Platform, deprecated: true
  field :working_directory, 6, type: :string, json_name: "workingDirectory"

  field :output_node_properties, 8,
    repeated: true,
    type: :string,
    json_name: "outputNodeProperties"

  field :output_directory_format, 9,
    type: Build.Bazel.Remote.Execution.V2.Command.OutputDirectoryFormat,
    json_name: "outputDirectoryFormat",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.Platform.Property do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Platform.Property",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end

defmodule Build.Bazel.Remote.Execution.V2.Platform do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Platform",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :properties, 1, repeated: true, type: Build.Bazel.Remote.Execution.V2.Platform.Property
end

defmodule Build.Bazel.Remote.Execution.V2.Directory do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Directory",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :files, 1, repeated: true, type: Build.Bazel.Remote.Execution.V2.FileNode
  field :directories, 2, repeated: true, type: Build.Bazel.Remote.Execution.V2.DirectoryNode
  field :symlinks, 3, repeated: true, type: Build.Bazel.Remote.Execution.V2.SymlinkNode

  field :node_properties, 5,
    type: Build.Bazel.Remote.Execution.V2.NodeProperties,
    json_name: "nodeProperties"
end

defmodule Build.Bazel.Remote.Execution.V2.NodeProperty do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.NodeProperty",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end

defmodule Build.Bazel.Remote.Execution.V2.NodeProperties do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.NodeProperties",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :properties, 1, repeated: true, type: Build.Bazel.Remote.Execution.V2.NodeProperty
  field :mtime, 2, type: Google.Protobuf.Timestamp
  field :unix_mode, 3, type: Google.Protobuf.UInt32Value, json_name: "unixMode"
end

defmodule Build.Bazel.Remote.Execution.V2.FileNode do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.FileNode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest
  field :is_executable, 4, type: :bool, json_name: "isExecutable"

  field :node_properties, 6,
    type: Build.Bazel.Remote.Execution.V2.NodeProperties,
    json_name: "nodeProperties"
end

defmodule Build.Bazel.Remote.Execution.V2.DirectoryNode do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.DirectoryNode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest
end

defmodule Build.Bazel.Remote.Execution.V2.SymlinkNode do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.SymlinkNode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :target, 2, type: :string

  field :node_properties, 4,
    type: Build.Bazel.Remote.Execution.V2.NodeProperties,
    json_name: "nodeProperties"
end

defmodule Build.Bazel.Remote.Execution.V2.Digest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Digest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hash, 1, type: :string
  field :size_bytes, 2, type: :int64, json_name: "sizeBytes"
end

defmodule Build.Bazel.Remote.Execution.V2.ExecutedActionMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecutedActionMetadata",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :worker, 1, type: :string
  field :queued_timestamp, 2, type: Google.Protobuf.Timestamp, json_name: "queuedTimestamp"

  field :worker_start_timestamp, 3,
    type: Google.Protobuf.Timestamp,
    json_name: "workerStartTimestamp"

  field :worker_completed_timestamp, 4,
    type: Google.Protobuf.Timestamp,
    json_name: "workerCompletedTimestamp"

  field :input_fetch_start_timestamp, 5,
    type: Google.Protobuf.Timestamp,
    json_name: "inputFetchStartTimestamp"

  field :input_fetch_completed_timestamp, 6,
    type: Google.Protobuf.Timestamp,
    json_name: "inputFetchCompletedTimestamp"

  field :execution_start_timestamp, 7,
    type: Google.Protobuf.Timestamp,
    json_name: "executionStartTimestamp"

  field :execution_completed_timestamp, 8,
    type: Google.Protobuf.Timestamp,
    json_name: "executionCompletedTimestamp"

  field :virtual_execution_duration, 12,
    type: Google.Protobuf.Duration,
    json_name: "virtualExecutionDuration"

  field :output_upload_start_timestamp, 9,
    type: Google.Protobuf.Timestamp,
    json_name: "outputUploadStartTimestamp"

  field :output_upload_completed_timestamp, 10,
    type: Google.Protobuf.Timestamp,
    json_name: "outputUploadCompletedTimestamp"

  field :auxiliary_metadata, 11,
    repeated: true,
    type: Google.Protobuf.Any,
    json_name: "auxiliaryMetadata"
end

defmodule Build.Bazel.Remote.Execution.V2.ActionResult do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ActionResult",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :output_files, 2,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.OutputFile,
    json_name: "outputFiles"

  field :output_file_symlinks, 10,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.OutputSymlink,
    json_name: "outputFileSymlinks",
    deprecated: true

  field :output_symlinks, 12,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.OutputSymlink,
    json_name: "outputSymlinks"

  field :output_directories, 3,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.OutputDirectory,
    json_name: "outputDirectories"

  field :output_directory_symlinks, 11,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.OutputSymlink,
    json_name: "outputDirectorySymlinks",
    deprecated: true

  field :exit_code, 4, type: :int32, json_name: "exitCode"
  field :stdout_raw, 5, type: :bytes, json_name: "stdoutRaw"
  field :stdout_digest, 6, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "stdoutDigest"
  field :stderr_raw, 7, type: :bytes, json_name: "stderrRaw"
  field :stderr_digest, 8, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "stderrDigest"

  field :execution_metadata, 9,
    type: Build.Bazel.Remote.Execution.V2.ExecutedActionMetadata,
    json_name: "executionMetadata"
end

defmodule Build.Bazel.Remote.Execution.V2.OutputFile do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.OutputFile",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest
  field :is_executable, 4, type: :bool, json_name: "isExecutable"
  field :contents, 5, type: :bytes

  field :node_properties, 7,
    type: Build.Bazel.Remote.Execution.V2.NodeProperties,
    json_name: "nodeProperties"
end

defmodule Build.Bazel.Remote.Execution.V2.Tree do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Tree",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :root, 1, type: Build.Bazel.Remote.Execution.V2.Directory
  field :children, 2, repeated: true, type: Build.Bazel.Remote.Execution.V2.Directory
end

defmodule Build.Bazel.Remote.Execution.V2.OutputDirectory do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.OutputDirectory",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :tree_digest, 3, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "treeDigest"
  field :is_topologically_sorted, 4, type: :bool, json_name: "isTopologicallySorted"

  field :root_directory_digest, 5,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "rootDirectoryDigest"
end

defmodule Build.Bazel.Remote.Execution.V2.OutputSymlink do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.OutputSymlink",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :target, 2, type: :string

  field :node_properties, 4,
    type: Build.Bazel.Remote.Execution.V2.NodeProperties,
    json_name: "nodeProperties"
end

defmodule Build.Bazel.Remote.Execution.V2.ExecutionPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecutionPolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :priority, 1, type: :int32
end

defmodule Build.Bazel.Remote.Execution.V2.ResultsCachePolicy do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ResultsCachePolicy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :priority, 1, type: :int32
end

defmodule Build.Bazel.Remote.Execution.V2.ExecuteRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecuteRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :skip_cache_lookup, 3, type: :bool, json_name: "skipCacheLookup"
  field :action_digest, 6, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "actionDigest"

  field :execution_policy, 7,
    type: Build.Bazel.Remote.Execution.V2.ExecutionPolicy,
    json_name: "executionPolicy"

  field :results_cache_policy, 8,
    type: Build.Bazel.Remote.Execution.V2.ResultsCachePolicy,
    json_name: "resultsCachePolicy"

  field :digest_function, 9,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true

  field :inline_stdout, 10, type: :bool, json_name: "inlineStdout"
  field :inline_stderr, 11, type: :bool, json_name: "inlineStderr"
  field :inline_output_files, 12, repeated: true, type: :string, json_name: "inlineOutputFiles"
end

defmodule Build.Bazel.Remote.Execution.V2.LogFile do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.LogFile",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :digest, 1, type: Build.Bazel.Remote.Execution.V2.Digest
  field :human_readable, 2, type: :bool, json_name: "humanReadable"
end

defmodule Build.Bazel.Remote.Execution.V2.ExecuteResponse.ServerLogsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecuteResponse.ServerLogsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Build.Bazel.Remote.Execution.V2.LogFile
end

defmodule Build.Bazel.Remote.Execution.V2.ExecuteResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecuteResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :result, 1, type: Build.Bazel.Remote.Execution.V2.ActionResult
  field :cached_result, 2, type: :bool, json_name: "cachedResult"
  field :status, 3, type: Google.Rpc.Status

  field :server_logs, 4,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.ExecuteResponse.ServerLogsEntry,
    json_name: "serverLogs",
    map: true

  field :message, 5, type: :string
end

defmodule Build.Bazel.Remote.Execution.V2.ExecutionStage do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecutionStage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Build.Bazel.Remote.Execution.V2.ExecuteOperationMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecuteOperationMetadata",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :stage, 1, type: Build.Bazel.Remote.Execution.V2.ExecutionStage.Value, enum: true
  field :action_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "actionDigest"
  field :stdout_stream_name, 3, type: :string, json_name: "stdoutStreamName"
  field :stderr_stream_name, 4, type: :string, json_name: "stderrStreamName"

  field :partial_execution_metadata, 5,
    type: Build.Bazel.Remote.Execution.V2.ExecutedActionMetadata,
    json_name: "partialExecutionMetadata"

  field :digest_function, 6,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.WaitExecutionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.WaitExecutionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule Build.Bazel.Remote.Execution.V2.GetActionResultRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.GetActionResultRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :action_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "actionDigest"
  field :inline_stdout, 3, type: :bool, json_name: "inlineStdout"
  field :inline_stderr, 4, type: :bool, json_name: "inlineStderr"
  field :inline_output_files, 5, repeated: true, type: :string, json_name: "inlineOutputFiles"

  field :digest_function, 6,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.UpdateActionResultRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.UpdateActionResultRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :action_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "actionDigest"

  field :action_result, 3,
    type: Build.Bazel.Remote.Execution.V2.ActionResult,
    json_name: "actionResult"

  field :results_cache_policy, 4,
    type: Build.Bazel.Remote.Execution.V2.ResultsCachePolicy,
    json_name: "resultsCachePolicy"

  field :digest_function, 5,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.FindMissingBlobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.FindMissingBlobsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"

  field :blob_digests, 2,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "blobDigests"

  field :digest_function, 3,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.FindMissingBlobsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.FindMissingBlobsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :missing_blob_digests, 2,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "missingBlobDigests"
end

defmodule Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsRequest.Request do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchUpdateBlobsRequest.Request",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :digest, 1, type: Build.Bazel.Remote.Execution.V2.Digest
  field :data, 2, type: :bytes
  field :compressor, 3, type: Build.Bazel.Remote.Execution.V2.Compressor.Value, enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchUpdateBlobsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"

  field :requests, 2,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsRequest.Request

  field :digest_function, 5,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsResponse.Response do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchUpdateBlobsResponse.Response",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :digest, 1, type: Build.Bazel.Remote.Execution.V2.Digest
  field :status, 2, type: Google.Rpc.Status
end

defmodule Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchUpdateBlobsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :responses, 1,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsResponse.Response
end

defmodule Build.Bazel.Remote.Execution.V2.BatchReadBlobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchReadBlobsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :digests, 2, repeated: true, type: Build.Bazel.Remote.Execution.V2.Digest

  field :acceptable_compressors, 3,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Compressor.Value,
    json_name: "acceptableCompressors",
    enum: true

  field :digest_function, 4,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.BatchReadBlobsResponse.Response do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchReadBlobsResponse.Response",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :digest, 1, type: Build.Bazel.Remote.Execution.V2.Digest
  field :data, 2, type: :bytes
  field :compressor, 4, type: Build.Bazel.Remote.Execution.V2.Compressor.Value, enum: true
  field :status, 3, type: Google.Rpc.Status
end

defmodule Build.Bazel.Remote.Execution.V2.BatchReadBlobsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.BatchReadBlobsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :responses, 1,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.BatchReadBlobsResponse.Response
end

defmodule Build.Bazel.Remote.Execution.V2.GetTreeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.GetTreeRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :root_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "rootDigest"
  field :page_size, 3, type: :int32, json_name: "pageSize"
  field :page_token, 4, type: :string, json_name: "pageToken"

  field :digest_function, 5,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.GetTreeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.GetTreeResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :directories, 1, repeated: true, type: Build.Bazel.Remote.Execution.V2.Directory
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule Build.Bazel.Remote.Execution.V2.SplitBlobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.SplitBlobRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :blob_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "blobDigest"

  field :digest_function, 3,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true

  field :chunking_function, 4,
    type: Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value,
    json_name: "chunkingFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.SplitBlobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.SplitBlobResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :chunk_digests, 1,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "chunkDigests"

  field :chunking_function, 2,
    type: Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value,
    json_name: "chunkingFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.GetChunkMappingResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.GetChunkMappingResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :chunk_digests, 1,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "chunkDigests"

  field :chunking_function, 2,
    type: Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value,
    json_name: "chunkingFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.SpliceBlobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.SpliceBlobRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :blob_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "blobDigest"

  field :chunk_digests, 3,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "chunkDigests"

  field :digest_function, 4,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true

  field :chunking_function, 5,
    type: Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value,
    json_name: "chunkingFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.RegisterChunkMappingRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.RegisterChunkMappingRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :blob_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "blobDigest"

  field :chunk_digests, 3,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Digest,
    json_name: "chunkDigests"

  field :digest_function, 4,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true

  field :chunking_function, 5,
    type: Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value,
    json_name: "chunkingFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.SpliceBlobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.SpliceBlobResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :blob_digest, 1, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "blobDigest"
end

defmodule Build.Bazel.Remote.Execution.V2.GetCapabilitiesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.GetCapabilitiesRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
end

defmodule Build.Bazel.Remote.Execution.V2.ServerCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ServerCapabilities",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :cache_capabilities, 1,
    type: Build.Bazel.Remote.Execution.V2.CacheCapabilities,
    json_name: "cacheCapabilities"

  field :execution_capabilities, 2,
    type: Build.Bazel.Remote.Execution.V2.ExecutionCapabilities,
    json_name: "executionCapabilities"

  field :deprecated_api_version, 3,
    type: Build.Bazel.Semver.SemVer,
    json_name: "deprecatedApiVersion"

  field :low_api_version, 4, type: Build.Bazel.Semver.SemVer, json_name: "lowApiVersion"
  field :high_api_version, 5, type: Build.Bazel.Semver.SemVer, json_name: "highApiVersion"
end

defmodule Build.Bazel.Remote.Execution.V2.DigestFunction do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.DigestFunction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Build.Bazel.Remote.Execution.V2.ChunkingFunction do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ChunkingFunction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Build.Bazel.Remote.Execution.V2.ActionCacheUpdateCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ActionCacheUpdateCapabilities",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :update_enabled, 1, type: :bool, json_name: "updateEnabled"
end

defmodule Build.Bazel.Remote.Execution.V2.PriorityCapabilities.PriorityRange do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.PriorityCapabilities.PriorityRange",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :min_priority, 1, type: :int32, json_name: "minPriority"
  field :max_priority, 2, type: :int32, json_name: "maxPriority"
end

defmodule Build.Bazel.Remote.Execution.V2.PriorityCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.PriorityCapabilities",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :priorities, 1,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.PriorityCapabilities.PriorityRange
end

defmodule Build.Bazel.Remote.Execution.V2.SymlinkAbsolutePathStrategy do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.SymlinkAbsolutePathStrategy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Build.Bazel.Remote.Execution.V2.Compressor do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.Compressor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Build.Bazel.Remote.Execution.V2.CacheCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.CacheCapabilities",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :digest_functions, 1,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunctions",
    enum: true

  field :action_cache_update_capabilities, 2,
    type: Build.Bazel.Remote.Execution.V2.ActionCacheUpdateCapabilities,
    json_name: "actionCacheUpdateCapabilities"

  field :cache_priority_capabilities, 3,
    type: Build.Bazel.Remote.Execution.V2.PriorityCapabilities,
    json_name: "cachePriorityCapabilities"

  field :max_batch_total_size_bytes, 4, type: :int64, json_name: "maxBatchTotalSizeBytes"

  field :symlink_absolute_path_strategy, 5,
    type: Build.Bazel.Remote.Execution.V2.SymlinkAbsolutePathStrategy.Value,
    json_name: "symlinkAbsolutePathStrategy",
    enum: true

  field :supported_compressors, 6,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Compressor.Value,
    json_name: "supportedCompressors",
    enum: true

  field :supported_batch_update_compressors, 7,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.Compressor.Value,
    json_name: "supportedBatchUpdateCompressors",
    enum: true

  field :max_cas_blob_size_bytes, 8, type: :int64, json_name: "maxCasBlobSizeBytes"
  field :split_blob_support, 9, type: :bool, json_name: "splitBlobSupport"
  field :splice_blob_support, 10, type: :bool, json_name: "spliceBlobSupport"

  field :fast_cdc_2020_params, 11,
    type: Build.Bazel.Remote.Execution.V2.FastCdc2020Params,
    json_name: "fastCdc2020Params"

  field :rep_max_cdc_params, 12,
    type: Build.Bazel.Remote.Execution.V2.RepMaxCdcParams,
    json_name: "repMaxCdcParams"
end

defmodule Build.Bazel.Remote.Execution.V2.FastCdc2020Params do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.FastCdc2020Params",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :avg_chunk_size_bytes, 1, type: :uint64, json_name: "avgChunkSizeBytes"
  field :seed, 2, type: :uint32
end

defmodule Build.Bazel.Remote.Execution.V2.RepMaxCdcParams do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.RepMaxCdcParams",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :min_chunk_size_bytes, 1, type: :uint64, json_name: "minChunkSizeBytes"
  field :horizon_size_bytes, 2, type: :uint64, json_name: "horizonSizeBytes"
end

defmodule Build.Bazel.Remote.Execution.V2.ExecutionCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ExecutionCapabilities",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :digest_function, 1,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true

  field :exec_enabled, 2, type: :bool, json_name: "execEnabled"

  field :execution_priority_capabilities, 3,
    type: Build.Bazel.Remote.Execution.V2.PriorityCapabilities,
    json_name: "executionPriorityCapabilities"

  field :supported_node_properties, 4,
    repeated: true,
    type: :string,
    json_name: "supportedNodeProperties"

  field :digest_functions, 5,
    repeated: true,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunctions",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.ToolDetails do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.ToolDetails",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tool_name, 1, type: :string, json_name: "toolName"
  field :tool_version, 2, type: :string, json_name: "toolVersion"
end

defmodule Build.Bazel.Remote.Execution.V2.RequestMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.RequestMetadata",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tool_details, 1,
    type: Build.Bazel.Remote.Execution.V2.ToolDetails,
    json_name: "toolDetails"

  field :action_id, 2, type: :string, json_name: "actionId"
  field :tool_invocation_id, 3, type: :string, json_name: "toolInvocationId"
  field :correlated_invocations_id, 4, type: :string, json_name: "correlatedInvocationsId"
  field :action_mnemonic, 5, type: :string, json_name: "actionMnemonic"
  field :target_id, 6, type: :string, json_name: "targetId"
  field :configuration_id, 7, type: :string, json_name: "configurationId"
end

defmodule Build.Bazel.Remote.Execution.V2.GetChunkMappingRequest do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.GetChunkMappingRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :instance_name, 1, type: :string, json_name: "instanceName"
  field :blob_digest, 2, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "blobDigest"

  field :digest_function, 3,
    type: Build.Bazel.Remote.Execution.V2.DigestFunction.Value,
    json_name: "digestFunction",
    enum: true

  field :chunking_function, 4,
    type: Build.Bazel.Remote.Execution.V2.ChunkingFunction.Value,
    json_name: "chunkingFunction",
    enum: true
end

defmodule Build.Bazel.Remote.Execution.V2.RegisterChunkMappingResponse do
  @moduledoc false

  use Protobuf,
    full_name: "build.bazel.remote.execution.v2.RegisterChunkMappingResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :blob_digest, 1, type: Build.Bazel.Remote.Execution.V2.Digest, json_name: "blobDigest"
end

defmodule Build.Bazel.Remote.Execution.V2.Execution.Service do
  @moduledoc false

  use GRPC.Service,
    name: "build.bazel.remote.execution.v2.Execution",
    protoc_gen_elixir_version: "0.17.0"

  rpc(
    :Execute,
    Build.Bazel.Remote.Execution.V2.ExecuteRequest,
    stream(Google.Longrunning.Operation)
  )

  rpc(
    :WaitExecution,
    Build.Bazel.Remote.Execution.V2.WaitExecutionRequest,
    stream(Google.Longrunning.Operation)
  )
end

defmodule Build.Bazel.Remote.Execution.V2.Execution.Stub do
  @moduledoc false

  use GRPC.Stub, service: Build.Bazel.Remote.Execution.V2.Execution.Service
end

defmodule Build.Bazel.Remote.Execution.V2.ActionCache.Service do
  @moduledoc false

  use GRPC.Service,
    name: "build.bazel.remote.execution.v2.ActionCache",
    protoc_gen_elixir_version: "0.17.0"

  rpc(
    :GetActionResult,
    Build.Bazel.Remote.Execution.V2.GetActionResultRequest,
    Build.Bazel.Remote.Execution.V2.ActionResult
  )

  rpc(
    :UpdateActionResult,
    Build.Bazel.Remote.Execution.V2.UpdateActionResultRequest,
    Build.Bazel.Remote.Execution.V2.ActionResult
  )
end

defmodule Build.Bazel.Remote.Execution.V2.ActionCache.Stub do
  @moduledoc false

  use GRPC.Stub, service: Build.Bazel.Remote.Execution.V2.ActionCache.Service
end

defmodule Build.Bazel.Remote.Execution.V2.ContentAddressableStorage.Service do
  @moduledoc false

  use GRPC.Service,
    name: "build.bazel.remote.execution.v2.ContentAddressableStorage",
    protoc_gen_elixir_version: "0.17.0"

  rpc(
    :FindMissingBlobs,
    Build.Bazel.Remote.Execution.V2.FindMissingBlobsRequest,
    Build.Bazel.Remote.Execution.V2.FindMissingBlobsResponse
  )

  rpc(
    :BatchUpdateBlobs,
    Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsRequest,
    Build.Bazel.Remote.Execution.V2.BatchUpdateBlobsResponse
  )

  rpc(
    :BatchReadBlobs,
    Build.Bazel.Remote.Execution.V2.BatchReadBlobsRequest,
    Build.Bazel.Remote.Execution.V2.BatchReadBlobsResponse
  )

  rpc(
    :GetTree,
    Build.Bazel.Remote.Execution.V2.GetTreeRequest,
    stream(Build.Bazel.Remote.Execution.V2.GetTreeResponse)
  )

  rpc(
    :SplitBlob,
    Build.Bazel.Remote.Execution.V2.SplitBlobRequest,
    Build.Bazel.Remote.Execution.V2.SplitBlobResponse
  )

  rpc(
    :GetChunkMapping,
    Build.Bazel.Remote.Execution.V2.GetChunkMappingRequest,
    stream(Build.Bazel.Remote.Execution.V2.GetChunkMappingResponse)
  )

  rpc(
    :SpliceBlob,
    Build.Bazel.Remote.Execution.V2.SpliceBlobRequest,
    Build.Bazel.Remote.Execution.V2.SpliceBlobResponse
  )

  rpc(
    :RegisterChunkMapping,
    stream(Build.Bazel.Remote.Execution.V2.RegisterChunkMappingRequest),
    Build.Bazel.Remote.Execution.V2.RegisterChunkMappingResponse
  )
end

defmodule Build.Bazel.Remote.Execution.V2.ContentAddressableStorage.Stub do
  @moduledoc false

  use GRPC.Stub, service: Build.Bazel.Remote.Execution.V2.ContentAddressableStorage.Service
end

defmodule Build.Bazel.Remote.Execution.V2.Capabilities.Service do
  @moduledoc false

  use GRPC.Service,
    name: "build.bazel.remote.execution.v2.Capabilities",
    protoc_gen_elixir_version: "0.17.0"

  rpc(
    :GetCapabilities,
    Build.Bazel.Remote.Execution.V2.GetCapabilitiesRequest,
    Build.Bazel.Remote.Execution.V2.ServerCapabilities
  )
end

defmodule Build.Bazel.Remote.Execution.V2.Capabilities.Stub do
  @moduledoc false

  use GRPC.Stub, service: Build.Bazel.Remote.Execution.V2.Capabilities.Service
end
