defmodule Conveyor.Repo.Migrations.StorageTuning do
  use Ecto.Migration

  @moduledoc """
  Production storage settings measured in M7:

    * invocations is updated ~3 times per build; the default autovacuum trigger (20 % of the
      table) lets dead tuples pile up on a large table, so vacuum at 2 %.
    * invocations.options averages ~20 KB compressed per build; LZ4 compresses it several
      times faster than pglz at a similar ratio.
    * segment payloads are already zstd-compressed by the ingest path; Postgres would try
      (and fail) to pglz-compress every one of them on insert. Store them EXTERNAL.
  """

  def up do
    execute "ALTER TABLE invocations SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02)"
    execute "ALTER TABLE invocations ALTER COLUMN options SET COMPRESSION lz4"
    execute "ALTER TABLE invocations ALTER COLUMN workspace_status SET COMPRESSION lz4"
    execute "ALTER TABLE invocation_metrics ALTER COLUMN build_metrics SET COMPRESSION lz4"
    execute "ALTER TABLE invocation_metrics ALTER COLUMN profile_summary SET COMPRESSION lz4"
    set_external("event_segments", "payload")
    set_external("log_segments", "data")
  end

  def down do
    execute "ALTER TABLE invocations RESET (autovacuum_vacuum_scale_factor, autovacuum_analyze_scale_factor)"
    execute "ALTER TABLE invocations ALTER COLUMN options SET COMPRESSION pglz"
    execute "ALTER TABLE invocations ALTER COLUMN workspace_status SET COMPRESSION pglz"
    execute "ALTER TABLE invocation_metrics ALTER COLUMN build_metrics SET COMPRESSION pglz"
    execute "ALTER TABLE invocation_metrics ALTER COLUMN profile_summary SET COMPRESSION pglz"
    execute "ALTER TABLE event_segments ALTER COLUMN payload SET STORAGE EXTENDED"
    execute "ALTER TABLE log_segments ALTER COLUMN data SET STORAGE EXTENDED"
  end

  # The parent and every existing partition; partitions created later copy the parent's
  # column storage.
  defp set_external(table, column) do
    execute """
    DO $$
    DECLARE part text;
    BEGIN
      EXECUTE format('ALTER TABLE %I ALTER COLUMN %I SET STORAGE EXTERNAL', '#{table}', '#{column}');
      FOR part IN
        SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = '#{table}'::regclass
      LOOP
        EXECUTE format('ALTER TABLE %I ALTER COLUMN %I SET STORAGE EXTERNAL', part, '#{column}');
      END LOOP;
    END $$;
    """
  end
end
