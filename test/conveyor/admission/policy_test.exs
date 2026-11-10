defmodule Conveyor.Admission.PolicyTest do
  use ExUnit.Case, async: true

  alias Conveyor.Admission.{Config, Policy}

  # 20 s deadline, no hold: an age of 1,000 ms is a pressure of 0.05. One-sample window
  # unless a row says otherwise.
  @config %Config{deadline_ms: 20_000, hold_ms: 0, window: 1, probe_ms: 0}

  defp run(samples, config \\ @config, state \\ nil) do
    samples
    |> Enum.with_index()
    |> Enum.map_reduce(state || Policy.new(config), fn {sample, i}, state ->
      {signals, now} =
        case sample do
          {signals, now} -> {signals, now}
          ms when is_integer(ms) -> {%{oldest_ms: ms}, i * 250}
          signals -> {signals, i * 250}
        end

      state = Policy.step(state, signals, now, config)
      {state, state}
    end)
    |> elem(0)
  end

  defp levels(samples, config \\ @config), do: samples |> run(config) |> Enum.map(& &1.level)

  describe "pressure" do
    test "is the worst of commit latency, pool queueing and backlog bytes, in deadlines" do
      c = %{@config | hold_ms: 1_000, queue_target_ms: 1_000, max_backlog_bytes: 1_000}

      for {signals, expected} <- [
            {%{}, 0.0},
            # The hold is not pressure: a batch is meant to wait that long.
            {%{oldest_ms: 1_000}, 0.0},
            {%{oldest_ms: 500}, 0.0},
            {%{oldest_ms: 6_000}, 0.25},
            {%{oldest_ms: 21_000}, 1.0},
            # A mean wait of the pool's target is half a deadline.
            {%{queue_ms: 500}, 0.25},
            {%{queue_ms: 2_000}, 1.0},
            {%{bytes: 250}, 0.25},
            {%{oldest_ms: 6_000, queue_ms: 1_000, bytes: 100}, 0.5}
          ] do
        assert_in_delta Policy.pressure(signals, c), expected, 0.0001, inspect(signals)
      end
    end
  end

  describe "levels" do
    # {ages of the oldest batch in ms, the level after each sample}
    for {name, ages, expected} <- [
          {"a healthy node stays normal", [0, 500, 2_900, 0], [0, 0, 0, 0]},
          {"each level is entered at its threshold", [3_000, 5_000, 14_999, 15_000],
           [1, 2, 2, 3]},
          {"a jump skips levels", [0, 16_000], [0, 3]},
          {"elevated is left at 1 s, not at 3 s", [3_000, 2_900, 1_100, 1_000], [1, 1, 1, 0]},
          {"shedding is left at 2 s, not at 5 s", [5_000, 4_900, 2_100, 2_000, 1_000],
           [2, 2, 2, 1, 0]},
          {"critical is left at 10 s, not at 15 s", [15_000, 14_000, 10_100, 10_000],
           [3, 3, 3, 2]},
          {"a fall skips levels", [16_000, 0], [3, 0]},
          {"a value between exit and enter keeps whatever level the node is in",
           [4_000, 4_000, 5_000, 4_000, 4_000], [1, 1, 2, 2, 2]}
        ] do
      test name do
        assert levels(unquote(ages)) == unquote(expected)
      end
    end

    test "no flapping around a threshold: one transition up, one down" do
      ages = [4_900, 5_100, 4_900, 5_100, 4_900, 5_100, 1_900, 2_100, 1_900]
      assert levels(ages) == [1, 2, 2, 2, 2, 2, 1, 1, 1]
    end

    test "the window takes the maximum: the gauge's zero between flushes is not a recovery" do
      c = %{@config | window: 4}
      # Leaves only after a full window below the exit threshold.
      assert levels([6_000, 0, 6_000, 0, 0, 0, 0, 0], c) == [2, 2, 2, 2, 2, 2, 0, 0]
    end

    test "disabled: the pressure is still measured, the level stays normal" do
      c = %{@config | enabled: false}
      assert [%{level: 0, events_pct: 0, pressure: p}] = run([19_000], c)
      assert_in_delta p, 0.95, 0.001
    end

    test "the share of streams whose events are refused grows from the critical threshold to the deadline" do
      pcts = [14_000, 15_000, 16_000, 17_500, 19_000, 20_000, 30_000, 12_000, 9_000]
      assert Enum.map(run(pcts), & &1.events_pct) == [0, 0, 20, 50, 80, 100, 100, 0, 0]
      # Still critical at 12 s (left at 10 s), with no event refused.
      assert Enum.map(run(pcts), & &1.level) == [2, 3, 3, 3, 3, 3, 3, 3, 2]
    end

    test "names" do
      assert Enum.map(0..3, &Policy.name/1) == [:normal, :elevated, :shedding, :critical]
    end
  end

  describe "readiness" do
    @healthy %{level: 0, db_ok: true}
    @shedding %{level: 2, db_ok: true}
    @config_r %{@config | unready_after_ms: 10_000, unready_min_ms: 30_000}

    defp ready(samples, config \\ @config_r), do: samples |> run(config) |> Enum.map(& &1.ready)
    defp at(ms, age, peers), do: {%{oldest_ms: age, peers: peers}, ms}

    test "a node alone sheds and stays in the balancer" do
      assert ready([at(0, 9_000, []), at(20_000, 9_000, []), at(120_000, 19_000, [])]) ==
               [true, true, true]
    end

    test "every node pressured (the database is the bottleneck): none leaves" do
      peers = List.duplicate(@shedding, 5)

      assert ready([at(0, 9_000, peers), at(20_000, 9_000, peers), at(600_000, 19_000, peers)]) ==
               [true, true, true]
    end

    test "half of the peers pressured is not an outlier either" do
      peers = [@shedding, @shedding, @healthy, @healthy]
      assert ready([at(0, 9_000, peers), at(20_000, 9_000, peers)]) == [true, true]
    end

    test "the one pressured node of a healthy cluster leaves after the sustain time, for at least the minimum" do
      peers = [@healthy, @healthy, @shedding]

      assert ready([
               at(0, 9_000, peers),
               # Shedding, but not for long enough yet.
               at(9_999, 9_000, peers),
               at(10_000, 9_000, peers),
               # Recovered at once: still out for the minimum (a balancer needs the time).
               at(11_000, 0, peers),
               at(39_999, 0, peers),
               at(40_000, 0, peers)
             ]) == [true, true, false, false, false, true]
    end

    test "out beyond the minimum for as long as it is still the outlier; back when the others shed too" do
      peers = [@healthy, @healthy]

      assert ready([
               at(0, 9_000, peers),
               at(10_000, 9_000, peers),
               at(50_000, 9_000, peers),
               at(60_000, 9_000, [@shedding, @shedding])
             ]) == [true, false, false, true]
    end

    test "a dip below shedding restarts the sustain time" do
      peers = [@healthy]

      assert ready([
               at(0, 9_000, peers),
               at(8_000, 0, peers),
               at(9_000, 9_000, peers),
               at(18_999, 9_000, peers),
               at(19_000, 9_000, peers)
             ]) == [true, true, true, true, false]
    end

    test "a node that has never reached its database is not ready" do
      c = %{@config | probe_ms: 2_000}
      assert ready([%{}, %{db: :error}, %{db: :ok}, %{}], c) == [false, false, true, true]
    end

    test "a database lost by this node alone: not ready after the failures in a row" do
      c = %{@config | probe_ms: 2_000, probe_failures: 3}
      ok = %{db: :ok}
      bad = %{db: :error}
      # No peers: the old behaviour.
      assert ready([ok, bad, bad, %{}, bad, ok], c) == [true, true, true, true, false, true]

      peers = [@healthy, @healthy, %{level: 0, db_ok: false}]
      bad = %{db: :error, peers: peers}
      assert ready([ok, bad, bad, bad], c) == [true, true, true, false]
    end

    test "a database lost by every node: none leaves" do
      c = %{@config | probe_ms: 2_000, probe_failures: 3}
      peers = [%{level: 0, db_ok: false}, %{level: 0, db_ok: false}, @healthy]
      bad = %{db: :error, peers: peers}
      assert ready([%{db: :ok}, bad, bad, bad, bad], c) == [true, true, true, true, true]
    end
  end

  describe "decide" do
    @open %{draining?: false, key_streams: 0, max_streams: 200}

    # {door, level, events_pct, request, decision}
    for {door, level, pct, request, decision} <- [
          # --- a stream is opened ---
          {:stream, 0, 0, @open, :accept},
          {:stream, 2, 0, @open, :accept},
          {:stream, 3, 0, @open, {:refuse, :overloaded}},
          {:stream, 0, 0, %{@open | draining?: true}, {:refuse, :draining}},
          {:stream, 3, 0, %{@open | draining?: true}, {:refuse, :draining}},
          {:stream, 0, 0, %{@open | key_streams: 200}, {:refuse, :key_streams}},
          {:stream, 0, 0, %{@open | key_streams: 199}, :accept},
          {:stream, 0, 0, %{@open | key_streams: 10_000, max_streams: :infinity}, :accept},
          # --- the build is known ---
          {:build, 0, 0, %{resumed?: false, over_share?: true}, :accept},
          {:build, 1, 0, %{resumed?: false, over_share?: false}, :accept},
          {:build, 1, 0, %{resumed?: false, over_share?: true}, {:refuse, :key_share}},
          {:build, 1, 0, %{resumed?: true, over_share?: true}, :accept},
          {:build, 2, 0, %{resumed?: false, over_share?: false}, {:refuse, :overloaded}},
          {:build, 2, 0, %{resumed?: true, over_share?: false}, :accept},
          {:build, 2, 0, %{resumed?: true, over_share?: true}, :accept},
          {:build, 3, 0, %{resumed?: true, over_share?: false}, {:refuse, :overloaded}},
          {:build, 3, 0, %{resumed?: false, over_share?: false}, {:refuse, :overloaded}},
          # --- the next event ---
          {:event, 0, 0, %{bucket: 0, token?: true}, :accept},
          {:event, 2, 0, %{bucket: 0, token?: true}, :accept},
          {:event, 3, 0, %{bucket: 0, token?: true}, :accept},
          {:event, 3, 20, %{bucket: 19, token?: true}, {:refuse, :overloaded}},
          {:event, 3, 20, %{bucket: 20, token?: true}, :accept},
          {:event, 3, 100, %{bucket: 99, token?: true}, {:refuse, :overloaded}},
          {:event, 0, 0, %{bucket: 0, token?: false}, {:slow, 10}},
          # Refused before slowed: a refused event must not wait for a token first.
          {:event, 3, 100, %{bucket: 5, token?: false}, {:refuse, :overloaded}}
        ] do
      test "#{door} at level #{level} (#{pct} %) #{inspect(request)} -> #{inspect(decision)}" do
        assert Policy.decide(
                 unquote(door),
                 %{level: unquote(level), events_pct: unquote(pct)},
                 unquote(Macro.escape(request))
               ) == unquote(Macro.escape(decision))
      end
    end
  end
end
