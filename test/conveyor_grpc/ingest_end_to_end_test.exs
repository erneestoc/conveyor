defmodule Conveyor.Grpc.IngestEndToEndTest do
  use Conveyor.IngestCase, async: false

  import Ecto.Query

  alias Conveyor.Bep.Replay
  alias Conveyor.Ingest.Verify
  alias Conveyor.Projects

  setup %{project: project} do
    {:ok, _key, plaintext} =
      Projects.create_api_key(project, %{name: "test", default_tags: %{"source" => "test"}})

    %{plaintext: plaintext}
  end

  @tag :capture_log
  test "replayed builds are persisted exactly once, including after a dropped connection", %{
    grpc_port: port,
    plaintext: key
  } do
    results =
      ~w(clean_build_and_test test_failure flaky_test build_failure analysis_failure cached_build_and_test build_only_verbose)
      |> Task.async_stream(&Replay.run(fixture(&1), port: port, api_key: key, drop_after: 7),
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, {:ok, r}} -> r end)

    for r <- results do
      assert Enum.uniq(r.acks) |> Enum.sort() == Enum.to_list(1..r.sent)

      case await_worker_exit(r.invocation_id) do
        :ok ->
          :ok

        other ->
          flunk(
            "worker still running: #{inspect(other)} summary=#{inspect(Conveyor.Ingest.Worker.summary(r.invocation_id) |> Map.take([:status, :last_event_seq, :stream_finished, :finalized, :event_count]))} sent=#{r.sent}"
          )
      end

      assert :ok = Verify.check(r.invocation_id, r.sent - 1)
      assert reload(r.invocation_id).tags["source"] == "test"
    end
  end

  @tag :capture_log
  test "wrong or missing keys are rejected", %{grpc_port: port} do
    assert {:error, {:lifecycle, %GRPC.RPCError{status: 16}}} =
             Replay.run(fixture("analysis_failure"), port: port)

    assert {:error, _} =
             Replay.run(fixture("analysis_failure"),
               port: port,
               api_key: "conveyor_bad_key",
               lifecycle: false
             )
  end

  @tag :capture_log
  test "the verify oracle reports problems", %{grpc_port: port, plaintext: key} do
    {:ok, r} = Replay.run(fixture("analysis_failure"), port: port, api_key: key)
    assert :ok = await_worker_exit(r.invocation_id)
    assert {:error, problems} = Verify.check(r.invocation_id, r.sent + 5)
    assert Enum.any?(problems, &match?({:last_event_seq, _, _}, &1))
    assert {:error, [{:missing_invocation, _}]} = Verify.check(Replay.uuid(), 1)

    Repo.update_all(from(i in Conveyor.Invocations.Invocation, where: i.id == ^r.invocation_id),
      set: [status: "in_progress", stream_finished: false]
    )

    assert {:error, problems} = Verify.check(r.invocation_id, r.sent - 1)

    assert {:stream_not_finished, "in_progress"} in problems and
             {:not_final, "in_progress"} in problems
  end
end
