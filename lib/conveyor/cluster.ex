defmodule Conveyor.Cluster do
  @moduledoc """
  Cluster formation (M7). `CLUSTER_STRATEGY` selects how nodes find each other:

    * `none` — single node (default)
    * `k8s` — Kubernetes headless service (`CLUSTER_K8S_SERVICE`, pods named
      `<basename>@<pod ip>`)
    * `dns` — poll an A record (`CLUSTER_DNS_QUERY`) for node IPs
    * `ec2` — instances tagged `CLUSTER_EC2_TAG=CLUSTER_EC2_TAG_VALUE` (instance role)
    * `epmd` — a static list of nodes (`CLUSTER_HOSTS=a@10.0.0.1,b@10.0.0.2`), for local
      multi-node testing

  Every node runs the same code: PubSub (PG) fans out live updates across nodes, API key
  cache invalidation travels over PubSub, ingest fencing works through the database, and
  the blob store must be shared (S3) once more than one node runs.
  """
  require Logger

  def config, do: Application.get_env(:conveyor, __MODULE__, [])

  @spec strategy() :: atom()
  def strategy, do: Keyword.get(config(), :strategy, :none)

  @doc "libcluster topologies for the configured strategy (empty when single node)."
  @spec topologies() :: keyword()
  def topologies do
    conf = config()
    basename = Keyword.get(conf, :node_basename, "conveyor")

    case strategy() do
      :none ->
        []

      :k8s ->
        [
          conveyor: [
            strategy: Cluster.Strategy.Kubernetes.DNS,
            config: [
              service: Keyword.fetch!(conf, :k8s_service),
              application_name: basename,
              polling_interval: Keyword.get(conf, :polling_interval, 5_000)
            ]
          ]
        ]

      :dns ->
        [
          conveyor: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              query: Keyword.fetch!(conf, :dns_query),
              node_basename: basename,
              polling_interval: Keyword.get(conf, :polling_interval, 5_000)
            ]
          ]
        ]

      :ec2 ->
        [
          conveyor: [
            strategy: Conveyor.Cluster.EC2,
            config: [
              tag: Keyword.get(conf, :ec2_tag, "conveyor-cluster"),
              tag_value: Keyword.fetch!(conf, :ec2_tag_value),
              node_basename: basename,
              region: Keyword.get(conf, :region),
              polling_interval: Keyword.get(conf, :polling_interval, 10_000)
            ]
          ]
        ]

      :epmd ->
        [conveyor: [strategy: Cluster.Strategy.Epmd, config: [hosts: host_atoms(conf)]]]

      other ->
        raise ArgumentError, "unknown CLUSTER_STRATEGY #{inspect(other)}"
    end
  end

  # Node names come from the operator's CLUSTER_HOSTS, a short fixed list.
  # sobelow_skip ["DOS.StringToAtom"]
  defp host_atoms(conf), do: conf |> Keyword.get(:hosts, []) |> Enum.map(&String.to_atom/1)

  @doc "Warns about configurations that cannot work across nodes."
  @spec check!() :: :ok
  def check! do
    if strategy() != :none do
      case Conveyor.Blobs.adapter() do
        {Conveyor.Blobs.Disk, _} ->
          Logger.warning(
            "CLUSTER_STRATEGY=#{strategy()} with the disk blob store: profiles and artifacts stored on one node are invisible to the others. Use BLOB_STORE=s3."
          )

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc "Parses `CLUSTER_HOSTS`."
  def parse_hosts(nil), do: []

  def parse_hosts(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end
