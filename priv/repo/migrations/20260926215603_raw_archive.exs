defmodule Conveyor.Repo.Migrations.RawArchive do
  use Ecto.Migration

  @moduledoc """
  Raw write-behind (`Conveyor.RawArchive`): a finished build's event and log segments are
  copied into one blob each and the build points at them. `raw_status` is `segments`
  until then, `archived` after, `skipped` when the segments did not match the row (the
  partition drop then treats the build as before the archive existed).

  None of these columns is indexed: an index on a column the per-batch update could touch
  makes every ingest update non-HOT. `inserted_at` never changes after the insert, so an
  index on it is safe; it bounds the archive's candidate scan and the partition drop's
  guard to the days whose partitions still exist.
  """

  def change do
    alter table(:invocations) do
      add :raw_status, :string, null: false, default: "segments"
      add :raw_blob, :string
      add :log_blob, :string
      add :raw_archived_at, :utc_datetime_usec
    end

    create index(:invocations, [:inserted_at])
  end
end
