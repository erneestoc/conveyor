defmodule Conveyor.Grpc.Endpoint do
  @moduledoc "gRPC endpoint exposing the Build Event Service to Bazel clients."
  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger, level: :debug)
  run(Conveyor.Grpc.PublishBuildEventServer)
end
