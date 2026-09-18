# Partitions and the default project are created once, outside the sandbox, so that tests
# see the same storage layout as a booted server.
Ecto.Adapters.SQL.Sandbox.mode(Conveyor.Repo, :auto)
:ok = Conveyor.Storage.boot()
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Conveyor.Repo, :manual)
