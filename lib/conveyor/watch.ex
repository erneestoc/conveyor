defmodule Conveyor.Watch do
  @moduledoc """
  Live updates only for builds somebody is looking at.

  Ingest workers publish a summary, detail and log-chunk message per build every
  `broadcast_interval_ms`; across a cluster, `Phoenix.PubSub` forwards every one of them to
  a single process on each other node, which fell behind at a few thousand concurrent
  streams per node (its queue grew to gigabytes and the node was killed out of memory,
  fleet test 2026-10-01). Viewers are rare and streams are many, so a topic is broadcast
  only while some process in the cluster has subscribed to it through this module: the
  subscription joins a `:pg` group named after the topic (replicated to every node,
  dropped when the subscriber exits) and publishers check that group, a local ETS read,
  before broadcasting.
  """

  @scope __MODULE__

  @doc false
  def child_spec(_opts), do: %{id: @scope, start: {:pg, :start_link, [@scope]}}

  @doc "Subscribes the calling process to a topic and marks the topic as watched cluster-wide."
  @spec subscribe(String.t()) :: :ok
  def subscribe(topic) do
    :ok = :pg.join(@scope, topic, self())
    Phoenix.PubSub.subscribe(Conveyor.PubSub, topic)
  end

  @doc "Whether any process in the cluster subscribed to the topic through `subscribe/1`."
  @spec watched?(String.t()) :: boolean()
  def watched?(topic), do: :pg.get_members(@scope, topic) != []

  @doc "Broadcasts a message on a topic if it is watched; a no-op otherwise."
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) do
    if watched?(topic), do: Phoenix.PubSub.broadcast(Conveyor.PubSub, topic, message), else: :ok
  end
end
