defmodule Conveyor.AdmissionTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Conveyor.{Admission, Limits}
  alias Conveyor.Admission.Sampler

  setup do
    Limits.reset()
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:conveyor, :admission, :refused], [:conveyor, :admission, :slowed]],
      fn [_, _, what], _, meta, _ -> send(test, {what, meta}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(id)
      Admission.resume()
      Sampler.inject([])
    end)

    :ok
  end

  defp limits(overrides), do: Map.merge(Limits.defaults(), Map.new(overrides))

  # Holds `n` stream slots of a key in a process of its own.
  defp hold(key, n) do
    test = self()

    pid =
      spawn_link(fn ->
        for _ <- 1..n, do: {:ok, _} = Admission.open_stream(key, limits(max_streams: 1_000))
        send(test, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    pid
  end

  describe "the stream door" do
    test "takes a slot of the key until the stream is closed" do
      assert {:ok, ticket} = Admission.open_stream(:k, limits(max_streams: 2))
      assert {:ok, _} = Admission.open_stream(:k, limits(max_streams: 2))
      assert {:refuse, :key_streams} = Admission.open_stream(:k, limits(max_streams: 2))
      assert_received {:refused, %{door: :stream, reason: :key_streams}}
      assert Admission.streams() == 2
      assert :ok = Admission.close_stream(ticket)
      assert {:ok, _} = Admission.open_stream(:k, limits(max_streams: 2))
    end

    test "without a key (auth none): counted, never limited" do
      for _ <- 1..3, do: assert({:ok, _} = Admission.open_stream(nil, limits(max_streams: 1)))
      assert Admission.streams() == 3
      assert %{streams: 3} = Admission.state()
    end

    test "a draining node refuses, and waits for its open streams" do
      holder = hold(:k, 2)
      assert Admission.drain(30) == :timeout
      assert Admission.draining?()
      assert {:refuse, :draining} = Admission.open_stream(:other)
      assert_received {:refused, %{door: :stream, reason: :draining}}
      assert %{ready: false, checks: %{draining: true}} = Admission.ready()

      Process.unlink(holder)
      Process.exit(holder, :kill)
      assert Admission.drain(2_000) == :ok
      assert Admission.resume() == :ok
      assert {:ok, _} = Admission.open_stream(:other)
      assert Admission.drain_timeout_ms() == 30_000
    end

    test "the build is not known when a stream opens: pressure is judged at its first event" do
      Sampler.inject(signals: %{oldest_ms: 21_000})
      assert {:ok, ticket} = Admission.open_stream(:k)
      assert {:refuse, :overloaded} = Admission.build(ticket, "b", true)
      assert :ok = Admission.close_stream(ticket)
      assert Admission.streams() == 0
    end
  end

  describe "the build door" do
    test "normal: everything" do
      assert :ok = Admission.build(:k, "b", false)
      {:ok, ticket} = Admission.open_stream(:k)
      assert :ok = Admission.build(ticket, "b", false)
    end

    test "elevated: the key above its share loses new builds, the others and resumed streams do not" do
      hold(:flood, 5)
      hold(:quiet, 1)
      Sampler.inject(signals: %{oldest_ms: 3_500})
      assert %{state: :elevated} = Admission.state()

      # Six streams over two keys: a share of three.
      assert {:refuse, :key_share} = Admission.build(:flood, "b", false)
      assert_received {:refused, %{door: :build, reason: :key_share}}
      assert :ok = Admission.build(:flood, "b", true)
      assert :ok = Admission.build(:quiet, "b", false)
      assert :ok = Admission.build(:newcomer, "b", false)
    end

    test "elevated: a key alone on the node is never above its share" do
      hold(:only, 5)
      Sampler.inject(signals: %{oldest_ms: 3_500})
      # Its own growth since the last sample does not count against it either.
      hold(:only, 3)
      assert :ok = Admission.build(:only, "b", false)
    end

    test "a build that was announced counts as in progress; the question is only asked under pressure" do
      assert :ok = Admission.build(:k, "b", false, fn -> flunk("asked on a normal node") end)
      Sampler.inject(signals: %{oldest_ms: 10_000})
      assert :ok = Admission.build(:k, "b", true, fn -> flunk("asked about a resumed stream") end)
      assert :ok = Admission.build(:k, "b", false, fn -> true end)
      assert {:refuse, :overloaded} = Admission.build(:k, "b", false, fn -> false end)
    end

    test "shedding: a share of the new builds that grows with the pressure, the same builds every time" do
      ids = for i <- 1..400, do: "build-#{i}"
      refused = fn -> Enum.filter(ids, &(Admission.build(:k, &1, false) != :ok)) end

      # (The test node's writer hold is 2 ms; pressure counts the age beyond it.)
      Sampler.inject(signals: %{oldest_ms: 5_002})
      assert %{state: :shedding, builds_refused_pct: 0} = Admission.state()
      assert refused.() == []

      Sampler.inject(signals: %{oldest_ms: 7_502})
      assert %{builds_refused_pct: 50} = Admission.state()
      half = refused.()
      assert length(half) in 150..250
      assert_received {:refused, %{door: :build, reason: :overloaded}}
      # A retry of a refused build is refused again; a build in progress is kept.
      assert refused.() == half
      assert :ok = Admission.build(:k, hd(half), true)

      Sampler.inject(signals: %{oldest_ms: 10_000})
      assert %{builds_refused_pct: 100} = Admission.state()
      assert length(refused.()) == 400
      {:ok, ticket} = Admission.open_stream(:k)
      assert {:refuse, :overloaded} = Admission.build(ticket, "b", false)
      assert :ok = Admission.build(ticket, "b", true)
      assert :ok = Admission.event(ticket)
    end

    test "critical: a share of the builds in progress too, the same ones at the stream and at the event" do
      ids = for i <- 1..200, do: "build-#{i}"
      {:ok, ticket} = Admission.open_stream(nil)

      refused_streams = fn -> Enum.filter(ids, &(Admission.build(nil, &1, true) != :ok)) end

      refused_events = fn ->
        Enum.filter(ids, &(Admission.event(Admission.bind(ticket, &1)) != :ok))
      end

      Sampler.inject(signals: %{oldest_ms: 15_002})

      assert %{state: :critical, events_refused_pct: 0, builds_refused_pct: 100} =
               Admission.state()

      assert refused_streams.() == []
      assert {:refuse, :overloaded} = Admission.build(nil, "new", false)

      Sampler.inject(signals: %{oldest_ms: 17_502})
      half = refused_streams.()
      assert length(half) in 60..140
      # A build that is shed is shed at every door, on every reconnect.
      assert refused_events.() == half
      assert refused_streams.() == half
      assert_received {:refused, %{door: :event, reason: :overloaded}}

      Sampler.inject(signals: %{oldest_ms: 20_002})
      assert length(refused_streams.()) == 200
      assert length(refused_events.()) == 200
    end
  end

  describe "the event door" do
    test "a key above its event rate is slowed down, not refused" do
      {:ok, ticket} = Admission.open_stream(:r, limits(max_events_per_second: 10))
      {elapsed_us, _} = :timer.tc(fn -> for _ <- 1..15, do: :ok = Admission.event(ticket) end)
      # 10 tokens are free, the next 5 arrive at 10/s: about half a second.
      assert elapsed_us >= 350_000
      # One count per slowed event, however long it waited.
      {:messages, messages} = Process.info(self(), :messages)
      assert Enum.count(messages, &match?({:slowed, _}, &1)) in 4..5
    end
  end

  test "state, readiness and the gauges" do
    test = self()
    id = {__MODULE__, :state}

    :telemetry.attach(
      id,
      [:conveyor, :admission, :state],
      fn _, m, _, _ -> send(test, {:gauges, m}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert %{
             ready: true,
             state: :normal,
             checks: %{database: true, draining: false, overloaded: false}
           } =
             Admission.ready()

    Sampler.inject(signals: %{oldest_ms: 6_000})
    assert :ok = Admission.measure()
    assert_received {:gauges, %{level: 2, ready: 1, pressure: p}}
    assert_in_delta p, 0.3, 0.01
  end

  test "one mapping to the wire" do
    assert %GRPC.RPCError{status: 14, message: "this node is draining" <> _} =
             Admission.grpc_error(:draining)

    assert %GRPC.RPCError{status: 14, message: "this node is overloaded" <> _} =
             Admission.grpc_error(:overloaded)

    assert %GRPC.RPCError{status: 14} = Admission.grpc_error(:key_share)

    assert %GRPC.RPCError{status: 8, message: "too many concurrent streams" <> rest} =
             Admission.grpc_error(:key_streams, limits(max_streams: 7))

    assert rest =~ "limit 7"
    assert {503, _} = Admission.http_error(:overloaded)
    assert {503, _} = Admission.http_error(:draining)
    assert {429, _} = Admission.http_error(:key_streams)
  end
end
