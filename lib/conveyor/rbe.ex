defmodule Conveyor.Rbe do
  @moduledoc """
  The RBE opportunity analysis (PLAN §27, docs/rbe-opportunity.md): would a shared cache
  or remote build execution save work, and how much.

  Two reports, both kept per project and hour by `Conveyor.Metrics.Rollup`:

    * `Conveyor.Rbe.Fleet`, from the event stream alone: executed work by runner and
      mnemonic, how much of each build executed, cold machines. A bound.
    * `Conveyor.Rbe.Hour`, from execution logs: every execution classed against the first
      execution of its action key (`Conveyor.ExecLog.ActionKey`, `Conveyor.ExecLog.Keys`).
      Exact for the builds that uploaded a log.

  `Conveyor.Rbe.Report` reads both for a window.
  """

  @doc """
  Adds two stored reports: numbers add, lists of numbers add by position, maps merge,
  other lists (examples) are concatenated and cut to five.
  """
  @spec sum(term(), term()) :: term()
  def sum(nil, b), do: b
  def sum(a, nil), do: a
  def sum(a, b) when is_number(a) and is_number(b), do: a + b
  def sum(a, b) when is_map(a) and is_map(b), do: Map.merge(a, b, fn _k, x, y -> sum(x, y) end)

  def sum([a | _] = x, [b | _] = y) when is_number(a) and is_number(b),
    do: Enum.zip_with(x, y, &(&1 + &2))

  def sum(a, b) when is_list(a) and is_list(b), do: Enum.take(Enum.uniq(a ++ b), 5)
end
