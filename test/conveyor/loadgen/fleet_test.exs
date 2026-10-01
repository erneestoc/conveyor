defmodule Conveyor.Loadgen.FleetTest do
  use ExUnit.Case, async: true

  alias Conveyor.Loadgen.Fleet

  test "derives the generator's arguments from the task environment" do
    assert Fleet.args(%{
             "LOADGEN_HOSTS" => "a:1985,b:1985",
             "LOADGEN_API_KEY" => "k",
             "LOADGEN_ARGS" => " --tls  --streams 250\n--delay-ms 500 "
           }) ==
             ~w(--hosts a:1985,b:1985 --api-key k --fixtures /corpus/*.bep --tls --streams 250 --delay-ms 500)

    assert Fleet.args(%{"LOADGEN_HOSTS" => "h:1985", "LOADGEN_FIXTURES" => "/x/*.bep"}) ==
             ~w(--hosts h:1985 --api-key) ++ ["", "--fixtures", "/x/*.bep"]

    assert_raise KeyError, fn -> Fleet.args(%{}) end
  end
end
