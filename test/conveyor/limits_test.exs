defmodule Conveyor.LimitsTest do
  use ExUnit.Case, async: false

  alias Conveyor.Limits

  setup do
    Limits.reset()
    :ok
  end

  test "defaults and per-key overrides" do
    assert %{max_streams: 200, max_events_per_second: 5000, max_log_bytes: 268_435_456} =
             Limits.defaults()

    assert Limits.for_key(nil) == Limits.defaults()

    assert Limits.for_key(%{limits: %{"max_streams" => 3, "max_log_bytes" => 0, "junk" => 1}}).max_streams ==
             3

    assert Limits.for_key(%{limits: %{"max_log_bytes" => 0}}).max_log_bytes ==
             Limits.defaults().max_log_bytes

    assert Limits.for_key(%{}) == Limits.defaults()
  end

  test "concurrent stream accounting" do
    limits = %{Limits.defaults() | max_streams: 2}
    assert :ok = Limits.acquire_stream(:k, limits)
    assert :ok = Limits.acquire_stream(:k, limits)
    assert {:error, :too_many_streams} = Limits.acquire_stream(:k, limits)
    assert Limits.streams(:k) == 2
    assert :ok = Limits.release_stream(:k)
    assert :ok = Limits.acquire_stream(:k, limits)
    assert :ok = Limits.release_stream(:k)
    assert :ok = Limits.release_stream(:k)
    assert :ok = Limits.release_stream(:k)
    Process.sleep(20)
    assert Limits.streams(:k) == 0
    assert Limits.streams(:other) == 0
    assert :ok = Limits.acquire_stream(nil, limits)
    assert :ok = Limits.release_stream(nil)

    # A slot held by a process that dies is released by the monitor.
    task = Task.async(fn -> Limits.acquire_stream(:dead, limits) end)
    assert :ok = Task.await(task)
    wait_until(fn -> Limits.streams(:dead) == 0 end)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "token bucket slows callers down to the configured rate" do
    limits = %{Limits.defaults() | max_events_per_second: 10}
    {elapsed_us, _} = :timer.tc(fn -> for _ <- 1..15, do: :ok = Limits.throttle(:r, limits) end)
    # 10 tokens are free, the next 5 arrive at 10/s: about half a second.
    assert elapsed_us >= 350_000
    assert :ok = Limits.throttle(nil, limits)
  end
end
