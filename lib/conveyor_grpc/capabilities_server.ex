defmodule Conveyor.Grpc.CapabilitiesServer do
  @moduledoc """
  `Capabilities.GetCapabilities` for the CAS sink: cache-only, SHA-256, no action cache
  updates, no execution. Bazel calls this first when `--remote_cache` points here.
  """
  use GRPC.Server, service: Build.Bazel.Remote.Execution.V2.Capabilities.Service

  alias Build.Bazel.Remote.Execution.V2, as: RE
  alias Conveyor.Grpc.{ByteStreamServer, CasServer}

  def get_capabilities(%RE.GetCapabilitiesRequest{}, stream) do
    ByteStreamServer.sink_enabled!()

    %RE.ServerCapabilities{
      cache_capabilities: %RE.CacheCapabilities{
        digest_functions: [:SHA256],
        action_cache_update_capabilities: %RE.ActionCacheUpdateCapabilities{update_enabled: false},
        max_batch_total_size_bytes: CasServer.max_batch_bytes(),
        symlink_absolute_path_strategy: :DISALLOWED,
        supported_compressors: [],
        supported_batch_update_compressors: []
      },
      low_api_version: %Build.Bazel.Semver.SemVer{major: 2, minor: 0},
      high_api_version: %Build.Bazel.Semver.SemVer{major: 2, minor: 3}
    }
    |> GRPC.Stream.unary(materializer: stream)
    |> GRPC.Stream.run()
  end
end
