defmodule Conveyor.Grpc.AckerTest do
  use ExUnit.Case, async: true

  alias Conveyor.Grpc.Acker

  defmodule FakeAdapter do
    def send_reply(%{test: test}, data, _opts), do: send(test, {:reply, data})
  end

  defp stream do
    %GRPC.Server.Stream{
      adapter: FakeAdapter,
      payload: %{test: self()},
      local: %{stream_id: nil},
      __interface__: %{
        send_reply: fn stream, reply, opts ->
          stream.adapter.send_reply(stream.payload, reply, opts)
        end
      }
    }
  end

  test "acks in order and finishes once the final sequence is acked" do
    acker = Acker.start(stream())
    send(acker, {:ack, 1})
    send(acker, {:ack, 2})
    Acker.final(acker, 3)
    send(acker, {:ack, 3})
    assert :ok = Acker.await(acker, 3, 1_000)
    assert_received {:reply, %{sequence_number: 1}}
    assert_received {:reply, %{sequence_number: 3}}
  end

  test "await without a final marker completes at the last sent sequence" do
    acker = Acker.start(stream())
    send(acker, {:ack, 1})
    assert :ok = Acker.await(acker, 1, 1_000)
  end

  test "failures propagate and timeouts are reported" do
    acker = Acker.start(stream())
    send(acker, {:ack_failed, 1, :boom})
    assert {:error, :boom} = Acker.await(acker, 1, 1_000)

    Process.flag(:trap_exit, true)
    acker2 = Acker.start(stream())
    assert {:error, :ack_timeout} = Acker.await(acker2, 5, 50)
    Process.exit(acker2, :kill)
  end
end
