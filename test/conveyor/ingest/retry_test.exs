defmodule Conveyor.Ingest.RetryTest do
  use ExUnit.Case, async: true

  alias Conveyor.Ingest.Retry

  @tag :capture_log
  test "retries transient errors with backoff and then gives up" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    flaky = fn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if n < 3, do: raise(DBConnection.ConnectionError, "pool exhausted"), else: :done
    end

    assert :done = Retry.with_backoff(flaky, delays: [1, 1, 1])
    assert Agent.get(counter, & &1) == 3

    Agent.update(counter, fn _ -> 0 end)
    assert_raise DBConnection.ConnectionError, fn -> Retry.with_backoff(flaky, delays: [1]) end
  end

  test "non-transient errors are raised immediately" do
    assert_raise ArgumentError, fn ->
      Retry.with_backoff(fn -> raise ArgumentError, "nope" end, delays: [1_000])
    end

    refute Retry.transient?(%ArgumentError{})
    assert Retry.transient?(%Postgrex.Error{postgres: %{code: :deadlock_detected}})
    refute Retry.transient?(%Postgrex.Error{postgres: %{code: :undefined_table}})
  end
end
