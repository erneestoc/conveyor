defmodule Conveyor.Repo.Migrations.HotUpdatesOnInvocations do
  use Ecto.Migration

  @moduledoc """
  Every ingest batch updates its invocation row (fenced `last_event_seq`, `last_event_at`,
  dirty columns). An index on `last_event_at` made all of those updates non-HOT, so each
  one rewrote every index on the table (3 % HOT updates measured at 200 streams; the
  index itself was never queried). Dropping it and leaving room on heap pages lets the
  per-batch updates stay in-page.
  """

  def up do
    drop index(:invocations, [:status, :last_event_at])
    execute "ALTER TABLE invocations SET (fillfactor = 70)"
  end

  def down do
    execute "ALTER TABLE invocations RESET (fillfactor)"
    create index(:invocations, [:status, :last_event_at])
  end
end
