# Partitions and the default project are created once, outside the sandbox, so that tests
# see the same storage layout as a booted server.
Ecto.Adapters.SQL.Sandbox.mode(Conveyor.Repo, :auto)
:ok = Conveyor.Storage.boot()
# Contract tests against real services run on demand: `mix test --only s3` (see
# test/conveyor/blobs/s3_contract_test.exs).
ExUnit.start(exclude: [:s3])
Ecto.Adapters.SQL.Sandbox.mode(Conveyor.Repo, :manual)
