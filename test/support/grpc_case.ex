defmodule Conveyor.GrpcCase do
  @moduledoc """
  Starts the Conveyor gRPC endpoint on a free port for the duration of a test module and
  exposes the port as `:grpc_port` in the test context.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Conveyor.GrpcCase, only: [fixture: 1]
    end
  end

  setup_all do
    port = free_port()

    pid =
      start_supervised!(
        {GRPC.Server.Supervisor,
         endpoint: Conveyor.Grpc.Endpoint, port: port, start_server: true},
        id: {:grpc_server, port}
      )

    on_exit(fn -> Process.alive?(pid) && Supervisor.stop(pid) end)
    {:ok, grpc_port: port}
  end

  def fixture(name), do: Path.join([File.cwd!(), "test/fixtures/bep", "#{name}.bep"])

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
