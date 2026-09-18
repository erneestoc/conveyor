defmodule Conveyor.ApplicationTest do
  use ExUnit.Case, async: true

  test "config_change forwards to the web endpoint" do
    assert Conveyor.Application.config_change([], [], []) == :ok
  end
end
