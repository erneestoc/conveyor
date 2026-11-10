defmodule Conveyor.Grpc.Endpoint do
  @moduledoc "gRPC endpoint exposing the Build Event Service to Bazel clients."
  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger, level: :debug)
  intercept Conveyor.Grpc.AuthInterceptor
  run(Conveyor.Grpc.PublishBuildEventServer)
  run(Conveyor.Grpc.ByteStreamServer)
  run(Conveyor.Grpc.CasServer)
  run(Conveyor.Grpc.CapabilitiesServer)
  run(Conveyor.Grpc.ActionCacheServer)

  @doc """
  Options of `GRPC.Server.Supervisor` for this endpoint on `port`: the one place that
  decides how the server is started (the application and the test cases call it), so the
  flow-control handler (`Conveyor.Grpc.FlowControl`) is never left out.
  """
  @spec server_opts(:inet.port_number(), keyword()) :: keyword()
  def server_opts(port, opts \\ []) do
    [
      endpoint: __MODULE__,
      port: port,
      start_server: Keyword.get(opts, :start_server, true),
      # Bazel can send multi-megabyte NamedSetOfFiles and progress chunks.
      max_body_size: Keyword.get(opts, :max_body_size, 64 * 1024 * 1024),
      adapter_opts: Conveyor.Grpc.FlowControl.adapter_opts(),
      exception_log_filter: {__MODULE__, :log_exception?}
    ]
  end

  @doc """
  Whether a handler's exception is logged. UNAVAILABLE and RESOURCE_EXHAUSTED are answers,
  not faults: admission refuses with them, by the thousand when a node sheds, and each is
  counted (`conveyor_admission_refused_count`). An error line with a stack trace per
  refusal would add load exactly then.
  """
  @spec log_exception?(GRPC.Server.Adapters.ReportException.t()) :: boolean()
  def log_exception?(%{reason: %GRPC.RPCError{status: status}}) when status in [8, 14], do: false
  def log_exception?(_exception), do: true
end
