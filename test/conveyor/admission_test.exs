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

    test "a critical node refuses every new stream" do
      Sampler.inject(signals: %{oldest_ms: 16_000})
      assert {:refuse, :overloaded} = Admission.open_stream(:k)
      assert Admission.streams() == 0
      Sampler.inject(signals: %{oldest_ms: 6_000})
      assert {:ok, _} = Admission.open_stream(:k)
    end
  end

  describe "the build door" do
    test "normal: everything" do
      assert :ok = Admission.build(:k, false)
      {:ok, ticket} = Admission.open_stream(:k)
      assert :ok = Admission.build(ticket, false)
    end

    test "elevated: the key above its share loses new builds, the others and resumed streams do not" do
      hold(:flood, 5)
      hold(:quiet, 1)
      Sampler.inject(signals: %{oldest_ms: 3_500})
      assert %{state: :elevated} = Admission.state()

      # Six streams over two keys: a share of three.
      assert {:refuse, :key_share} = Admission.build(:flood, false)
      assert_received {:refused, %{door: :build, reason: :key_share}}
      assert :ok = Admission.build(:flood, true)
      assert :ok = Admission.build(:quiet, false)
      assert :ok = Admission.build(:newcomer, false)
    end

    test "shedding: new builds are refused, a build in progress is kept" do
      Sampler.inject(signals: %{oldest_ms: 6_000})
      assert {:ok, ticket} = Admission.open_stream(:k)
      assert {:refuse, :overloaded} = Admission.build(ticket, false)
      assert_received {:refused, %{door: :build, reason: :overloaded}}
      assert :ok = Admission.build(ticket, true)
      assert :ok = Admission.event(ticket)
    end

    test "critical: resumed streams too" do
      Sampler.inject(signals: %{oldest_ms: 16_000})
      assert {:refuse, :overloaded} = Admission.build(:k, true)
    end
  end

  describe "the event door" do
    test "refuses the events of a growing share of streams as the deadline approaches" do
      tickets = for _ <- 1..200, do: elem(Admission.open_stream(nil), 1)
      refused = fn -> Enum.count(tickets, &(Admission.event(&1) == {:refuse, :overloaded})) end

      Sampler.inject(signals: %{oldest_ms: 15_000})
      assert refused.() == 0
      Sampler.inject(signals: %{oldest_ms: 17_500})
      half = refused.()
      assert half in 60..140
      assert_received {:refused, %{door: :event, reason: :overloaded}}
      # The same streams are refused each time: a stream is shed or kept, not sampled.
      assert refused.() == half
      Sampler.inject(signals: %{oldest_ms: 20_000})
      assert refused.() == 200
    end

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
