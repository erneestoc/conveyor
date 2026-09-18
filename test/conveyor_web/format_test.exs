defmodule ConveyorWeb.FormatTest do
  use ExUnit.Case, async: true

  alias ConveyorWeb.Format

  test "durations" do
    assert Format.duration(nil) == "—"
    assert Format.duration(250) == "250ms"
    assert Format.duration(1_500) == "1.5s"
    assert Format.duration(65_000) == "1m 05s"
    assert Format.duration(3_720_000) == "1h 02m"
  end

  test "bytes, numbers, percentages" do
    assert Format.bytes(nil) == "—" and Format.bytes(512) == "512 B"

    assert Format.bytes(2_048) == "2.0 KB" and Format.bytes(3 * 1_048_576) == "3.0 MB" and
             Format.bytes(2 * 1_073_741_824) == "2.0 GB"

    assert Format.number(nil) == "—" and Format.number(1_234_567) == "1,234,567" and
             Format.number(12) == "12"

    assert Format.percent(1, 0) == nil and Format.percent(nil, 5) == nil and
             Format.percent(1, 3) == "33%"

    assert Format.cache_hit_rate(%{remote_cache_hits: 5, actions_executed: 10}) == "50%"
  end

  test "relative times and iso" do
    now = ~U[2026-09-18 12:00:00Z]
    assert Format.relative(nil, now) == "—"
    assert Format.relative(~U[2026-09-18 11:59:30Z], now) == "just now"
    assert Format.relative(~U[2026-09-18 11:30:00Z], now) == "30m ago"
    assert Format.relative(~U[2026-09-18 09:00:00Z], now) == "3h ago"
    assert Format.relative(~U[2026-09-17 09:00:00Z], now) == "yesterday"
    assert Format.relative(~U[2026-09-10 09:00:00Z], now) == "8d ago"
    assert Format.relative(~U[2026-01-10 09:00:00Z], now) == "2026-01-10"
    assert Format.iso(nil) == nil and Format.iso(now) == "2026-09-18T12:00:00Z"
  end

  test "command line and truncate" do
    assert Format.command_line(%{command: "test", patterns: ["//a", "//b"]}) ==
             "bazel test //a //b"

    assert Format.command_line(%{command: nil, patterns: nil}) == "bazel ?"

    assert Format.truncate(nil, 3) == "" and Format.truncate("abc", 3) == "abc" and
             Format.truncate("abcdef", 4) == "abc…"
  end
end
