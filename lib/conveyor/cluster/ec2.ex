defmodule Conveyor.Cluster.EC2 do
  @moduledoc """
  libcluster strategy for EC2 auto-scaling groups: polls `DescribeInstances` for running
  instances carrying a tag (`tag`/`tag_value`, e.g. `conveyor-cluster=prod`) and connects
  to `<node_basename>@<private ip>`. Uses the instance role through `Conveyor.Aws`; the
  role needs `ec2:DescribeInstances`.

      config: [tag: "conveyor-cluster", tag_value: "prod", node_basename: "conveyor",
               polling_interval: 10_000]
  """
  use GenServer
  require Logger

  alias Cluster.Strategy
  alias Cluster.Strategy.State

  @default_polling_interval 10_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{meta: nil} = state]), do: init([%State{state | meta: MapSet.new()}])
  def init([%State{} = state]), do: {:ok, poll(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp poll(
         %State{
           topology: topology,
           connect: connect,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state
       ) do
    nodes = state |> discover() |> MapSet.new()
    removed = MapSet.difference(state.meta, nodes)

    nodes =
      case Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
        :ok -> nodes
        {:error, bad} -> Enum.reduce(bad, nodes, fn {n, _}, acc -> MapSet.put(acc, n) end)
      end

    nodes =
      case Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(nodes)) do
        :ok -> nodes
        {:error, bad} -> Enum.reduce(bad, nodes, fn {n, _}, acc -> MapSet.delete(acc, n) end)
      end

    Process.send_after(
      self(),
      :poll,
      Keyword.get(state.config, :polling_interval, @default_polling_interval)
    )

    %State{state | meta: nodes}
  end

  @doc "Node names for the instances currently carrying the tag (excluding this node)."
  # One atom per cluster member, from the EC2 API the operator's role is allowed to query.
  # sobelow_skip ["DOS.BinToAtom"]
  def discover(%State{config: config}) do
    tag = Keyword.fetch!(config, :tag)
    value = Keyword.fetch!(config, :tag_value)
    basename = Keyword.get(config, :node_basename, "conveyor")
    aws_opts = Keyword.take(config, [:region, :endpoint, :access_key_id, :secret_access_key])

    case Conveyor.Aws.describe_instances_by_tag(tag, value, aws_opts) do
      {:ok, ips} ->
        ips |> Enum.map(&:"#{basename}@#{&1}") |> Enum.reject(&(&1 == node()))

      {:error, reason} ->
        Logger.warning("ec2 cluster discovery failed: #{inspect(reason)}")
        []
    end
  end
end
