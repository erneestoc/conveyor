defmodule Conveyor.WatchTest do
  use Conveyor.IngestCase, async: false

  alias Conveyor.Bep.Replay
  alias Conveyor.{Ingest, Watch}

  test "a topic is broadcast only while a process subscribed to it through Watch" do
    topic = "watch-test:#{System.unique_integer([:positive])}"
    refute Watch.watched?(topic)

    # A plain PubSub subscriber does not count: the publisher skips the broadcast.
    Phoenix.PubSub.subscribe(Conveyor.PubSub, topic)
    Watch.broadcast(topic, :unwatched)
    refute_receive :unwatched, 50

    watcher =
      spawn(fn ->
        Watch.subscribe(topic)

        receive do
          :stop -> :ok
        end
      end)

    # Membership is registered by the subscriber itself; wait until it is visible.
    wait_until(fn -> Watch.watched?(topic) end)
    Watch.broadcast(topic, :watched)
    assert_receive :watched

    ref = Process.monitor(watcher)
    send(watcher, :stop)
    assert_receive {:DOWN, ^ref, :process, ^watcher, _}
    wait_until(fn -> not Watch.watched?(topic) end)
    Watch.broadcast(topic, :gone)
    refute_receive :gone, 50
  end

  test "ingest workers publish a build's updates only to watched topics", %{
    project: project,
    grpc_port: port
  } do
    {:ok, _key, key} = Conveyor.Projects.create_api_key(project, %{name: "watch"})
    id = Replay.uuid()

    # Nobody watches: no detail or log messages leave the worker.
    Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.invocation_topic(id))
    Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.log_topic(id))
    Watch.subscribe(Ingest.project_topic(project.id))

    assert {:ok, _} =
             Replay.run(fixture("clean_build_and_test"),
               port: port,
               api_key: key,
               invocation_id: id
             )

    :ok = await_worker_exit(id)
    assert_received {:invocation_updated, %{id: ^id}}
    refute_received {:invocation_detail, _}
    refute_received {:log_chunks, _, _}
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
