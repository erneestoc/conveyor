defmodule Mix.Tasks.Conveyor.SeedTest do
  use Conveyor.DataCase, async: false

  test "the mix task seeds the default project" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Mix.Tasks.Conveyor.Seed.run(["--invocations", "30", "--days", "3"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "inserted 30 invocations"
    assert Conveyor.Repo.aggregate(Conveyor.Invocations.Invocation, :count) >= 30
  end
end
