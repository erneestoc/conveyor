defmodule Conveyor.Workers.ObanRescueTest do
  use ExUnit.Case, async: true

  # docs/spec/Oban.tla: a job may only be rescued by Lifeline after its own timeout has
  # killed it, or the same parse runs twice at once (seen on the AWS trial).
  test "the parse timeout is shorter than the Lifeline rescue window" do
    plugins = Application.get_env(:conveyor, Oban)[:plugins]
    {Oban.Plugins.Lifeline, opts} = Enum.find(plugins, &match?({Oban.Plugins.Lifeline, _}, &1))

    assert Conveyor.Workers.ParseExecLog.timeout(%Oban.Job{}) <
             Keyword.fetch!(opts, :rescue_after)
  end
end
