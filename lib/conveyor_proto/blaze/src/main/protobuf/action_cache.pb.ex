defmodule Blaze.ActionCacheStatistics.MissReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "blaze.ActionCacheStatistics.MissReason",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :DIFFERENT_ACTION_KEY, 0
  field :DIFFERENT_DEPS, 1
  field :DIFFERENT_ENVIRONMENT, 2
  field :DIFFERENT_FILES, 3
  field :CORRUPTED_CACHE_ENTRY, 4
  field :NOT_CACHED, 5
  field :UNCONDITIONAL_EXECUTION, 6
  field :DIGEST_MISMATCH, 7
end

defmodule Blaze.ActionCacheStatistics.MissDetail do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.ActionCacheStatistics.MissDetail",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reason, 1, type: Blaze.ActionCacheStatistics.MissReason, enum: true
  field :count, 2, type: :int32
end

defmodule Blaze.ActionCacheStatistics do
  @moduledoc false

  use Protobuf,
    full_name: "blaze.ActionCacheStatistics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :size_in_bytes, 1, type: :uint64, json_name: "sizeInBytes"
  field :save_time_in_ms, 2, type: :uint64, json_name: "saveTimeInMs"
  field :hits, 3, type: :int32
  field :misses, 4, type: :int32

  field :miss_details, 5,
    repeated: true,
    type: Blaze.ActionCacheStatistics.MissDetail,
    json_name: "missDetails"

  field :load_time_in_ms, 6, type: :uint64, json_name: "loadTimeInMs"

  field :cache_check_semaphore_wait_time_in_ms, 7,
    type: :uint64,
    json_name: "cacheCheckSemaphoreWaitTimeInMs"
end
