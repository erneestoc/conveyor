defmodule Conveyor.RawStore.ExpiryTest do
  use ExUnit.Case, async: true

  alias Conveyor.RawStore.Expiry

  @now ~U[2026-11-20 10:30:00Z]

  test "rule 1: partitions of days strictly before today − R may be dropped" do
    assert Expiry.partition_cutoff(~D[2026-11-20], 14) == ~D[2026-11-06]
    assert Expiry.partition_cutoff(~D[2026-11-20], 1) == ~D[2026-11-19]
    assert Expiry.raw_days() == Application.get_env(:conveyor, :retention_raw_days, 14)
  end

  test "rule 2: objects registered before now − (R + 1) days, and before the oldest partition" do
    by_age = ~U[2026-11-05 10:30:00Z]
    # No partition left, or only younger ones: age decides.
    assert Expiry.object_cutoff(@now, 14, nil) == by_age
    assert Expiry.object_cutoff(@now, 14, ~D[2026-11-06]) == by_age
    # A partition kept past its date (a stalled drop, the archive's guard) keeps every
    # object registered on or after its day (docs/spec/RawLog.tla).
    assert Expiry.object_cutoff(@now, 14, ~D[2026-11-05]) == ~U[2026-11-05 00:00:00Z]
    assert Expiry.object_cutoff(@now, 14, ~D[2026-10-01]) == ~U[2026-10-01 00:00:00Z]
  end

  test "rule 3: compaction is due H hours after the finish, for builds whose partition exists" do
    assert Expiry.compaction_due_before(@now, 24) == ~U[2026-11-19 10:30:00Z]
    assert Expiry.compaction_window(@now, 24, nil) == nil

    assert Expiry.compaction_window(@now, 24, ~D[2026-11-10]) ==
             {~U[2026-11-10 00:00:00Z], ~U[2026-11-19 10:30:00Z]}

    assert Expiry.day_span(~D[2026-11-10]) == {~U[2026-11-10 00:00:00Z], ~U[2026-11-11 00:00:00Z]}
  end
end
