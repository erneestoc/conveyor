defmodule Conveyor.Query.ValuesTest do
  use ExUnit.Case, async: true

  alias Conveyor.Query.Values

  test "durations" do
    assert Values.duration("5m") == {:ok, 300_000}
    assert Values.duration("2h30m") == {:ok, 9_000_000}
    assert Values.duration("500ms") == {:ok, 500}
    assert Values.duration("1.5s") == {:ok, 1_500}
    assert Values.duration("90") == {:ok, 90_000}
    assert Values.duration("1d") == {:ok, 86_400_000}
    assert Values.duration("abc") == :error
    assert Values.duration("5 m") == :error
  end

  test "datetimes" do
    now = ~U[2026-09-18 12:00:00Z]
    assert Values.datetime("-24h", now) == {:ok, ~U[2026-09-17 12:00:00Z]}
    assert Values.datetime("-7d", now) == {:ok, ~U[2026-09-11 12:00:00Z]}
    assert Values.datetime("2026-09-01", now) == {:ok, ~U[2026-09-01 00:00:00Z]}
    assert Values.datetime("2026-09-01T10:00:00Z", now) == {:ok, ~U[2026-09-01 10:00:00Z]}
    assert Values.datetime("yesterday", now) == :error
    assert Values.datetime("-x", now) == :error
  end

  test "numbers" do
    assert Values.number("3") == {:ok, 3} and Values.number("3.5") == {:ok, 3.5} and
             Values.number("x") == :error

    assert Values.numeric?("10") and not Values.numeric?("ten")
  end
end
