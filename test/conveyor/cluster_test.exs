defmodule Conveyor.ClusterTest do
  use ExUnit.Case, async: false

  alias Conveyor.Cluster, as: ConveyorCluster

  setup do
    previous = Application.get_env(:conveyor, Conveyor.Cluster)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Cluster, previous) end)
    %{previous: previous}
  end

  defp configure(overrides, prev),
    do: Application.put_env(:conveyor, Conveyor.Cluster, Keyword.merge(prev, overrides))

  test "topologies follow the configured strategy", %{previous: prev} do
    assert ConveyorCluster.topologies() == []
    assert ConveyorCluster.strategy() == :none

    configure([strategy: :k8s, k8s_service: "conveyor-headless"], prev)

    assert [conveyor: [strategy: Cluster.Strategy.Kubernetes.DNS, config: config]] =
             ConveyorCluster.topologies()

    assert config[:service] == "conveyor-headless" and config[:application_name] == "conveyor"

    configure([strategy: :dns, dns_query: "conveyor.internal"], prev)

    assert [conveyor: [strategy: Cluster.Strategy.DNSPoll, config: config]] =
             ConveyorCluster.topologies()

    assert config[:query] == "conveyor.internal"

    configure([strategy: :ec2, ec2_tag_value: "prod", region: "us-east-1"], prev)

    assert [conveyor: [strategy: Conveyor.Cluster.EC2, config: config]] =
             ConveyorCluster.topologies()

    assert config[:tag] == "conveyor-cluster" and config[:tag_value] == "prod"

    configure([strategy: :epmd, hosts: ["a@127.0.0.1", "b@127.0.0.1"]], prev)

    assert [
             conveyor: [
               strategy: Cluster.Strategy.Epmd,
               config: [hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]]
             ]
           ] = ConveyorCluster.topologies()

    configure([strategy: :bogus], prev)
    assert_raise ArgumentError, fn -> ConveyorCluster.topologies() end

    assert ConveyorCluster.parse_hosts(nil) == [] and
             ConveyorCluster.parse_hosts("a@1, b@2,") == ["a@1", "b@2"]
  end

  @tag :capture_log
  test "warns when clustered with the disk blob store", %{previous: prev} do
    assert :ok = ConveyorCluster.check!()
    configure([strategy: :epmd, hosts: []], prev)
    assert :ok = ConveyorCluster.check!()
  end

  test "the EC2 strategy discovers tagged instances and connects them" do
    endpoint = Conveyor.FakeAws.start()
    previous = Application.get_env(:conveyor, Conveyor.Aws)
    Application.put_env(:conveyor, Conveyor.Aws, imds_endpoint: endpoint)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Aws, previous || []) end)
    Conveyor.Aws.reset()
    test = self()

    state = %Cluster.Strategy.State{
      topology: :conveyor,
      connect: {__MODULE__, :connect, [test]},
      disconnect: {__MODULE__, :disconnect, [test]},
      list_nodes: {__MODULE__, :list_nodes, [test]},
      config: [
        tag: "conveyor-cluster",
        tag_value: "prod",
        node_basename: "conveyor",
        endpoint: endpoint,
        region: "us-east-1",
        polling_interval: 60_000
      ]
    }

    assert Conveyor.Cluster.EC2.discover(state) == [:"conveyor@10.0.0.7", :"conveyor@10.0.0.8"]
    {:ok, pid} = Conveyor.Cluster.EC2.start_link([state])
    assert_receive {:connect, :"conveyor@10.0.0.7"}
    assert_receive {:connect, :"conveyor@10.0.0.8"}
    send(pid, :poll)
    send(pid, :other)
    GenServer.stop(pid)

    down = %{state | config: Keyword.put(state.config, :endpoint, "http://127.0.0.1:1")}
    assert Conveyor.Cluster.EC2.discover(down) == []
  end

  # libcluster appends the node to the configured arguments.
  def connect(test, node) do
    send(test, {:connect, node})
    true
  end

  def disconnect(test, node) do
    send(test, {:disconnect, node})
    true
  end

  def list_nodes(_test), do: []
end
