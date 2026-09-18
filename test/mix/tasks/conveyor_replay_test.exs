defmodule Mix.Tasks.Conveyor.ReplayTest do
  use Conveyor.GrpcCase, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  @tag :capture_log
  test "replays files and reports acks", %{grpc_port: port} do
    Mix.Tasks.Conveyor.Replay.run([
      fixture("build_failure"),
      fixture("flaky_test"),
      "--port",
      "#{port}",
      "--repeat",
      "2",
      "--concurrency",
      "2",
      "--api-key",
      "k"
    ])

    messages = collect_shell_messages()
    assert Enum.count(messages, &(&1 =~ ~r/events, \d+ ms, ok$/)) == 4
    assert Enum.any?(messages, &(&1 =~ "4/4 replays succeeded"))
  end

  @tag :capture_log
  test "reports failures and exits non-zero" do
    assert catch_exit(
             Mix.Tasks.Conveyor.Replay.run([
               fixture("build_failure"),
               "--port",
               "1",
               "--host",
               "127.0.0.1"
             ])
           ) ==
             {:shutdown, 1}

    assert Enum.any?(collect_shell_messages(), &(&1 =~ "FAILED"))
  end

  test "requires at least one file" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Conveyor.Replay.run([]) end
  end

  defp collect_shell_messages(acc \\ []) do
    receive do
      {:mix_shell, _, [msg]} -> collect_shell_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
