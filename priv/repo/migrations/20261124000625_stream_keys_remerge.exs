defmodule Conveyor.Repo.Migrations.StreamKeysRemerge do
  use Ecto.Migration

  # PLAN §28.7: the classification of per-action records changed (an execution reported
  # by several builds is one execution; the others were served it). The rule needs a
  # key row per execution, written when a build's keys are merged. Builds whose records
  # still exist are marked as not merged: the rollup job merges them again within five
  # minutes (idempotent), which touches them, so their hours that are not final yet are
  # rolled again under the new rule. Hours already final keep their numbers.
  def up do
    execute("""
    UPDATE invocations i SET stream_keys_at = NULL
    WHERE i.stream_actions > 0 AND i.stream_keys_at IS NOT NULL
      AND EXISTS (SELECT 1 FROM stream_actions c WHERE c.invocation_id = i.id)
    """)
  end

  def down, do: :ok
end
