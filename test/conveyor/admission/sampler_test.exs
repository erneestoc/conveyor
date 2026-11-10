defmodule Conveyor.Admission.SamplerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Conveyor.Admission
  alias Conveyor.Admission.Sampler

  setup do
    on_exit(fn -> Sampler.inject([]) end)
    :ok
  end

  test "an injected signal reaches the doors' cell; recovery needs a full window" do
    assert %{level: 0} = Sampler.inject([])
    assert %{level: 2, pressure: p} = Sampler.inject(signals: %{oldest_ms: 6_000})
    assert_in_delta p, 0.3, 0.01
    assert %{level: 2, state: :shedding, ready: true} = Admission.state()

    assert %{level: 3, events_pct: 100} = Sampler.inject(signals: fn -> %{oldest_ms: 60_000} end)
    assert %{state: :critical, events_refused_pct: 100} = Admission.state()

    # Back to the node's own signals: the level is a fresh state's.
    assert %{level: 0} = Sampler.inject([])
    assert %{level: 0, state: :normal, events_refused_pct: 0} = Admission.state()
    assert %{level: 0} = Sampler.policy()
  end

  test "the node's own signals: the writer pool's pressure and the mean pool queue time" do
    # A pool target of 100 ms: a mean wait of 150 ms is 0.75 of a deadline.
    assert %{level: 0} = Sampler.inject(config: [queue_target_ms: 100, window: 1])
    ms = System.convert_time_unit(1, :millisecond, :native)
    for _ <- 1..10, do: Conveyor.Histogram.observe("conveyor.repo.query.queue_time", 150 * ms)
    assert %{level: 3, pressure: p} = Sampler.sample()
    assert_in_delta p, 0.75, 0.05
    # No query since: nothing waited.
    assert %{level: 0} = Sampler.sample()
  end

  test "peers: the one shedding node of a healthy cluster leaves the balancer; a shared cause keeps it in" do
    config = [unready_after_ms: 0, unready_min_ms: 0, peer_ttl_ms: 60_000]
    assert %{ready: true} = Sampler.inject(signals: %{oldest_ms: 6_000}, config: config)

    send(Sampler, {:admission, :a@elsewhere, 0, true})
    send(Sampler, {:admission, :b@elsewhere, 0, true})
    # A node's own report is not a peer.
    send(Sampler, {:admission, node(), 0, true})
    assert %{ready: false, level: 2} = Sampler.sample()
    assert %{ready: false, checks: %{overloaded: true, database: true}} = Admission.ready()

    send(Sampler, {:admission, :a@elsewhere, 2, true})
    send(Sampler, {:admission, :b@elsewhere, 3, true})
    assert %{ready: true, level: 2} = Sampler.sample()
    assert %{ready: true, checks: %{overloaded: true}} = Admission.ready()
  end

  test "reports older than the peer TTL are not counted" do
    config = [unready_after_ms: 0, unready_min_ms: 0, peer_ttl_ms: 0]
    assert %{ready: true} = Sampler.inject(signals: %{oldest_ms: 6_000}, config: config)
    send(Sampler, {:admission, :a@elsewhere, 0, true})
    Process.sleep(5)
    assert %{ready: true} = Sampler.sample()
  end

  test "the database probe runs beside the sampler; failures in a row make a lone node not ready" do
    test = self()

    probe = fn ->
      send(test, :probed)
      :error
    end

    assert %{ready: false} =
             Sampler.inject(probe: probe, config: [probe_ms: 10, probe_failures: 2])

    assert_receive :probed
    assert_receive :probed
    assert_receive :probed
    assert %{ready: false, db_seen: false} = Sampler.sample()
    assert %{ready: false, checks: %{database: false}} = Admission.ready()

    assert %{} = Sampler.inject(probe: fn -> :ok end, config: [probe_ms: 10])
    wait_until(fn -> Sampler.sample().db_seen end)
    assert %{ready: true, checks: %{database: true}} = Admission.ready()

    # A probe that crashes or never answers counts as a failure, and the samples go on.
    assert %{} =
             Sampler.inject(
               probe: fn -> exit(:boom) end,
               config: [probe_ms: 10, probe_failures: 1]
             )

    wait_until(fn -> Sampler.sample().db_failures > 0 end)

    assert %{} = Sampler.inject(probe: fn -> Process.sleep(:infinity) end, config: [probe_ms: 10])
    assert %{level: 0} = Sampler.sample(3)
  end

  test "the default probe asks the database" do
    assert Sampler.probe_database() in [:ok, :error]
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
