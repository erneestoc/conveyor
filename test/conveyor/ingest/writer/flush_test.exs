defmodule Conveyor.Ingest.Writer.FlushTest do
  use ExUnit.Case, async: true

  alias Conveyor.Ingest.Writer.{Config, Flush}

  @postgres %Config{hold_ms: 20, max_pending: 256, max_bytes: nil}
  @blob %Config{hold_ms: 1000, max_pending: 256, max_bytes: 4_194_304, blob?: true}

  defp waiting(overrides),
    do: Map.merge(%{count: 1, bytes: 100, oldest_ms: 0, finalize?: false}, Map.new(overrides))

  for {name, waiting, config, decision} <- [
        {"the first batch waits out the hold", [], :postgres, {:wait, 20}},
        {"a later batch waits for what is left of it", [count: 3, oldest_ms: 15], :postgres,
         {:wait, 5}},
        {"a batch that queued longer than the hold waits no more, but is not a flush",
         [oldest_ms: 3_000], :postgres, {:wait, 0}},
        {"a clock that stepped back is no reason to wait longer than the hold", [oldest_ms: -5],
         :postgres, {:wait, 20}},
        {"a full group commits at once", [count: 256], :postgres, :flush},
        {"one short of full still waits", [count: 255, oldest_ms: 1], :postgres, {:wait, 19}},
        {"the end of a stream never waits", [finalize?: true], :postgres, :flush},
        {"postgres mode has no byte limit", [bytes: 1_000_000_000], :postgres, {:wait, 20}},
        {"blob mode holds for the raw log's interval", [], :blob, {:wait, 1000}},
        {"blob mode commits once enough bytes wait", [count: 9, bytes: 4_194_304], :blob, :flush},
        {"blob mode below the byte limit waits", [count: 9, bytes: 4_194_303, oldest_ms: 400],
         :blob, {:wait, 600}},
        {"the end of a stream does not wait for blob mode's hold either",
         [finalize?: true, oldest_ms: 1], :blob, :flush}
      ] do
    test name do
      config = if unquote(config) == :blob, do: @blob, else: @postgres
      assert Flush.decide(waiting(unquote(waiting)), config) == unquote(decision)
    end
  end
end
