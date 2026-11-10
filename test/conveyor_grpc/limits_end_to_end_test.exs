defmodule Conveyor.Grpc.LimitsEndToEndTest do
  # The limits that are not admission (the stream and rate limits are in
  # admission_end_to_end_test.exs): the log cap, and what a key's limits may be.
  use Conveyor.IngestCase, async: false

  @moduletag :capture_log

  alias Conveyor.Bep.Replay
  alias Conveyor.{Invocations, Limits, Projects}

  setup do
    Limits.reset()
    :ok
  end

  test "the build log is capped per invocation", %{project: project, grpc_port: port} do
    {:ok, _key, plaintext} =
      Projects.create_api_key(project, %{name: "small", limits: %{"max_log_bytes" => 200}})

    assert {:ok, r} = Replay.run(fixture("clean_build_and_test"), port: port, api_key: plaintext)
    :ok = await_worker_exit(r.invocation_id)
    inv = Conveyor.Repo.get!(Conveyor.Invocations.Invocation, r.invocation_id)
    log = Invocations.log(inv)
    assert log =~ "build log truncated at 200 bytes"
    assert inv.log_bytes < 400
    assert inv.event_count == r.sent - 1
  end

  test "invalid limits are rejected", %{project: project} do
    assert {:error, changeset} =
             Projects.create_api_key(project, %{name: "bad", limits: %{"max_streams" => -1}})

    assert "keys must be" <> _ = hd(errors_on(changeset).limits)
    {:ok, key, _} = Projects.create_api_key(project, %{name: "ok"})
    assert {:ok, key} = Projects.update_api_key_limits(key, %{"max_log_bytes" => 1024})
    assert Limits.for_key(key).max_log_bytes == 1024
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
