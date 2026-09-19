defmodule Conveyor.Grpc.Endpoint do
  @moduledoc "gRPC endpoint exposing the Build Event Service to Bazel clients."
  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger, level: :debug)
  intercept Conveyor.Grpc.AuthInterceptor
  run(Conveyor.Grpc.PublishBuildEventServer)
  run(Conveyor.Grpc.ByteStreamServer)
end
