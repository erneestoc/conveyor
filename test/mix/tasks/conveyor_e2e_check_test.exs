defmodule Mix.Tasks.Conveyor.E2eCheckTest do
  use ConveyorWeb.LiveCase

  alias Mix.Tasks.Conveyor.E2eCheck

  test "verifies the newest build for a Bazel version and reports what is missing" do
    ctx = %{context() | api_key_tags: %{"bazel" => "9.9.9"}}
    ingest_fixture!("clean_build_and_test", ctx)
    assert :ok = E2eCheck.check("9.9.9", System.monotonic_time(:millisecond) + 5_000)

    failed_ctx = %{context() | api_key_tags: %{"bazel" => "8.8.8"}}
    ingest_fixture!("build_failure", failed_ctx)
    assert {:error, reason} = E2eCheck.check("8.8.8", System.monotonic_time(:millisecond))
    assert reason =~ "status is failed"

    assert {:error, "no invocation tagged bazel=1.0.0"} =
             E2eCheck.check("1.0.0", System.monotonic_time(:millisecond))

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    E2eCheck.run(["--bazel", "9.9.9", "--timeout-s", "1"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "e2e ok"

    assert_raise Mix.Error, ~r/e2e check failed/, fn ->
      E2eCheck.run(["--bazel", "1.0.0", "--timeout-s", "0"])
    end
  end
end
