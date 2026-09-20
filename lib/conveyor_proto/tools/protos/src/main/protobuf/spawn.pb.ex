defmodule Tools.Protos.Digest do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.Digest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hash, 1, type: :string
  field :size_bytes, 2, type: :int64, json_name: "sizeBytes"
  field :hash_function_name, 3, type: :string, json_name: "hashFunctionName"
end

defmodule Tools.Protos.File do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.File",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :symlink_target_path, 4, type: :string, json_name: "symlinkTargetPath"
  field :digest, 2, type: Tools.Protos.Digest
  field :is_tool, 3, type: :bool, json_name: "isTool"
end

defmodule Tools.Protos.EnvironmentVariable do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.EnvironmentVariable",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end

defmodule Tools.Protos.Platform.Property do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.Platform.Property",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end

defmodule Tools.Protos.Platform do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.Platform",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :properties, 1, repeated: true, type: Tools.Protos.Platform.Property
end

defmodule Tools.Protos.SpawnMetrics do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.SpawnMetrics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :total_time, 1, type: Google.Protobuf.Duration, json_name: "totalTime"
  field :parse_time, 2, type: Google.Protobuf.Duration, json_name: "parseTime"
  field :network_time, 3, type: Google.Protobuf.Duration, json_name: "networkTime"
  field :fetch_time, 4, type: Google.Protobuf.Duration, json_name: "fetchTime"
  field :queue_time, 5, type: Google.Protobuf.Duration, json_name: "queueTime"
  field :setup_time, 6, type: Google.Protobuf.Duration, json_name: "setupTime"
  field :upload_time, 7, type: Google.Protobuf.Duration, json_name: "uploadTime"
  field :execution_wall_time, 8, type: Google.Protobuf.Duration, json_name: "executionWallTime"
  field :process_outputs_time, 9, type: Google.Protobuf.Duration, json_name: "processOutputsTime"
  field :retry_time, 10, type: Google.Protobuf.Duration, json_name: "retryTime"
  field :input_bytes, 11, type: :int64, json_name: "inputBytes"
  field :input_files, 12, type: :int64, json_name: "inputFiles"
  field :memory_estimate_bytes, 13, type: :int64, json_name: "memoryEstimateBytes"
  field :input_bytes_limit, 14, type: :int64, json_name: "inputBytesLimit"
  field :input_files_limit, 15, type: :int64, json_name: "inputFilesLimit"
  field :output_bytes_limit, 16, type: :int64, json_name: "outputBytesLimit"
  field :output_files_limit, 17, type: :int64, json_name: "outputFilesLimit"
  field :memory_bytes_limit, 18, type: :int64, json_name: "memoryBytesLimit"
  field :time_limit, 19, type: Google.Protobuf.Duration, json_name: "timeLimit"
  field :start_time, 20, type: Google.Protobuf.Timestamp, json_name: "startTime"
  field :measured_memory_peak_bytes, 21, type: :int64, json_name: "measuredMemoryPeakBytes"
end

defmodule Tools.Protos.SpawnExec do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.SpawnExec",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :command_args, 1, repeated: true, type: :string, json_name: "commandArgs"

  field :environment_variables, 2,
    repeated: true,
    type: Tools.Protos.EnvironmentVariable,
    json_name: "environmentVariables"

  field :platform, 3, type: Tools.Protos.Platform
  field :inputs, 4, repeated: true, type: Tools.Protos.File
  field :listed_outputs, 5, repeated: true, type: :string, json_name: "listedOutputs"
  field :remotable, 6, type: :bool
  field :cacheable, 7, type: :bool
  field :timeout_millis, 8, type: :int64, json_name: "timeoutMillis"
  field :mnemonic, 10, type: :string
  field :actual_outputs, 11, repeated: true, type: Tools.Protos.File, json_name: "actualOutputs"
  field :runner, 12, type: :string
  field :cache_hit, 13, type: :bool, json_name: "cacheHit"
  field :status, 14, type: :string
  field :exit_code, 15, type: :int32, json_name: "exitCode"
  field :remote_cacheable, 16, type: :bool, json_name: "remoteCacheable"
  field :target_label, 18, type: :string, json_name: "targetLabel"
  field :digest, 19, type: Tools.Protos.Digest
  field :metrics, 20, type: Tools.Protos.SpawnMetrics
end

defmodule Tools.Protos.ExecLogEntry.Invocation do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.Invocation",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hash_function_name, 1, type: :string, json_name: "hashFunctionName"
  field :workspace_runfiles_directory, 2, type: :string, json_name: "workspaceRunfilesDirectory"
  field :sibling_repository_layout, 3, type: :bool, json_name: "siblingRepositoryLayout"
  field :id, 4, type: :string
end

defmodule Tools.Protos.ExecLogEntry.File do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.File",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :digest, 2, type: Tools.Protos.Digest
end

defmodule Tools.Protos.ExecLogEntry.Directory do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.Directory",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :files, 2, repeated: true, type: Tools.Protos.ExecLogEntry.File
end

defmodule Tools.Protos.ExecLogEntry.UnresolvedSymlink do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.UnresolvedSymlink",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :target_path, 2, type: :string, json_name: "targetPath"
end

defmodule Tools.Protos.ExecLogEntry.InputSet do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.InputSet",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :input_ids, 5, repeated: true, type: :uint32, json_name: "inputIds"
  field :transitive_set_ids, 4, repeated: true, type: :uint32, json_name: "transitiveSetIds"
end

defmodule Tools.Protos.ExecLogEntry.SymlinkEntrySet.DirectEntriesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.SymlinkEntrySet.DirectEntriesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :uint32
end

defmodule Tools.Protos.ExecLogEntry.SymlinkEntrySet do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.SymlinkEntrySet",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :direct_entries, 1,
    repeated: true,
    type: Tools.Protos.ExecLogEntry.SymlinkEntrySet.DirectEntriesEntry,
    json_name: "directEntries",
    map: true

  field :transitive_set_ids, 2, repeated: true, type: :uint32, json_name: "transitiveSetIds"
end

defmodule Tools.Protos.ExecLogEntry.RunfilesTree do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.RunfilesTree",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :input_set_id, 2, type: :uint32, json_name: "inputSetId"
  field :symlinks_id, 3, type: :uint32, json_name: "symlinksId"
  field :root_symlinks_id, 4, type: :uint32, json_name: "rootSymlinksId"
  field :empty_files, 5, repeated: true, type: :string, json_name: "emptyFiles"

  field :repo_mapping_manifest, 6,
    type: Tools.Protos.ExecLogEntry.File,
    json_name: "repoMappingManifest"
end

defmodule Tools.Protos.ExecLogEntry.Output do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.Output",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:type, 0)

  field :output_id, 5, type: :uint32, json_name: "outputId", oneof: 0
  field :invalid_output_path, 4, type: :string, json_name: "invalidOutputPath", oneof: 0
end

defmodule Tools.Protos.ExecLogEntry.Spawn do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.Spawn",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :args, 1, repeated: true, type: :string
  field :env_vars, 2, repeated: true, type: Tools.Protos.EnvironmentVariable, json_name: "envVars"
  field :platform, 3, type: Tools.Protos.Platform
  field :input_set_id, 4, type: :uint32, json_name: "inputSetId"
  field :tool_set_id, 5, type: :uint32, json_name: "toolSetId"
  field :outputs, 6, repeated: true, type: Tools.Protos.ExecLogEntry.Output
  field :target_label, 7, type: :string, json_name: "targetLabel"
  field :mnemonic, 8, type: :string
  field :exit_code, 9, type: :int32, json_name: "exitCode"
  field :status, 10, type: :string
  field :runner, 11, type: :string
  field :cache_hit, 12, type: :bool, json_name: "cacheHit"
  field :remotable, 13, type: :bool
  field :cacheable, 14, type: :bool
  field :remote_cacheable, 15, type: :bool, json_name: "remoteCacheable"
  field :digest, 16, type: Tools.Protos.Digest
  field :timeout_millis, 17, type: :int64, json_name: "timeoutMillis"
  field :metrics, 18, type: Tools.Protos.SpawnMetrics
end

defmodule Tools.Protos.ExecLogEntry.SymlinkAction do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry.SymlinkAction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :input_path, 1, type: :string, json_name: "inputPath"
  field :output_path, 2, type: :string, json_name: "outputPath"
  field :target_label, 3, type: :string, json_name: "targetLabel"
  field :mnemonic, 4, type: :string
end

defmodule Tools.Protos.ExecLogEntry do
  @moduledoc false

  use Protobuf,
    full_name: "tools.protos.ExecLogEntry",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:type, 0)

  field :id, 1, type: :uint32
  field :invocation, 2, type: Tools.Protos.ExecLogEntry.Invocation, oneof: 0
  field :file, 3, type: Tools.Protos.ExecLogEntry.File, oneof: 0
  field :directory, 4, type: Tools.Protos.ExecLogEntry.Directory, oneof: 0

  field :unresolved_symlink, 5,
    type: Tools.Protos.ExecLogEntry.UnresolvedSymlink,
    json_name: "unresolvedSymlink",
    oneof: 0

  field :input_set, 6, type: Tools.Protos.ExecLogEntry.InputSet, json_name: "inputSet", oneof: 0
  field :spawn, 7, type: Tools.Protos.ExecLogEntry.Spawn, oneof: 0

  field :symlink_action, 8,
    type: Tools.Protos.ExecLogEntry.SymlinkAction,
    json_name: "symlinkAction",
    oneof: 0

  field :symlink_entry_set, 9,
    type: Tools.Protos.ExecLogEntry.SymlinkEntrySet,
    json_name: "symlinkEntrySet",
    oneof: 0

  field :runfiles_tree, 10,
    type: Tools.Protos.ExecLogEntry.RunfilesTree,
    json_name: "runfilesTree",
    oneof: 0
end
