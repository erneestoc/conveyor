defmodule ConveyorWeb.InvocationLiveTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.Ingest

  setup do
    ctx = context()

    %{
      ctx: ctx,
      failed_id: ingest_fixture!("build_failure", ctx),
      test_id: ingest_fixture!("flaky_test", ctx),
      ok_id: ingest_fixture!("clean_build_and_test", ctx)
    }
  end

  test "overview shows the header, failure summary and timing", %{conn: conn, failed_id: id} do
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}")
    assert has_element?(view, "#command-line", "bazel build")
    assert has_element?(view, "#exit-category", "build failed")
    assert has_element?(view, "#failure-summary", "//lib:broken")
    assert has_element?(view, "#phases")
    assert has_element?(view, "#execution-summary")
    assert has_element?(view, "#mnemonics")
    assert has_element?(view, "#tab-overview[aria-selected=true]")
  end

  test "targets, tests, actions, details and events tabs", %{
    conn: conn,
    ok_id: ok_id,
    test_id: test_id,
    failed_id: failed_id
  } do
    {:ok, view, _} = live(conn, ~p"/invocation/#{ok_id}/targets")
    assert has_element?(view, "#targets tr[data-status=success]")
    assert has_element?(view, "#slowest-tests") == false

    view |> element("#tab-tests") |> render_click()
    assert_patch(view, ~p"/invocation/#{ok_id}/tests")
    assert has_element?(view, "#tests tr[data-verdict=PASSED]")

    {:ok, view, _} = live(conn, ~p"/invocation/#{test_id}/tests")
    assert has_element?(view, "#tests tr[data-verdict=FLAKY]")

    {:ok, view, _} = live(conn, ~p"/invocation/#{failed_id}/actions")
    assert has_element?(view, "#actions tr[data-success=false]")

    {:ok, view, _} = live(conn, ~p"/invocation/#{ok_id}/details")
    assert has_element?(view, "#unstructured-command-line")
    assert has_element?(view, "#tags")

    {:ok, view, _} = live(conn, ~p"/invocation/#{ok_id}/events")
    assert has_element?(view, "#event-1")
    assert has_element?(view, "#download-events")
    refute has_element?(view, "#events-next")
    {:ok, view, _} = live(conn, ~p"/invocation/#{ok_id}/events?page=99")
    assert has_element?(view, "#events")

    {:ok, view, _} = live(conn, ~p"/invocation/#{ok_id}/nonsense")
    assert has_element?(view, "#tab-overview[aria-selected=true]")
  end

  test "log tab serves the log and streams chunks", %{conn: conn, ok_id: id} do
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/log")
    assert has_element?(view, "#log-viewer")
    assert has_element?(view, "#download-log")
    assert {:ok, _} = Ecto.UUID.cast(id)
    render_hook(view, "log:load", %{})
    assert_push_event(view, "log:reset", %{text: text, live: false, truncated: false})
    assert text =~ "Build completed successfully"

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.log_topic(id),
      {:log_chunks, ["more output\n"]}
    )

    assert_push_event(view, "log:append", %{text: "more output\n"})
  end

  test "live digests update the header and the open tab", %{conn: conn, ok_id: id} do
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/targets")

    detail = %{
      invocation: %{id: id, status: "in_progress", targets_failed: 3, tests_failed: 1},
      targets: [%{label: "//new:target", aspect: "", status: "failed", failure_message: "boom"}],
      tests: [%{label: "//new:target", run: 1, shard: 1, attempt: 1, status: "FAILED"}],
      actions: [%{seq: 999, mnemonic: "Javac", success: false, exit_code: 1}]
    }

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.invocation_topic(id),
      {:invocation_detail, detail}
    )

    assert has_element?(view, "#targets tr[data-status=failed]", "//new:target")
    assert has_element?(view, "[data-status=in_progress]")

    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/tests")

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.invocation_topic(id),
      {:invocation_detail, detail}
    )

    assert has_element?(view, "#tests tr[data-verdict=FAILED]", "//new:target")

    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/actions")

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.invocation_topic(id),
      {:invocation_detail, detail}
    )

    assert has_element?(view, "#action-999")

    {:ok, view, _} = live(conn, ~p"/invocation/#{id}")

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.invocation_topic(id),
      {:invocation_detail, detail}
    )

    assert has_element?(view, "#header-stats")
  end

  test "unknown invocations are 404", %{conn: conn} do
    assert_raise ConveyorWeb.NotFoundError, fn ->
      live(conn, ~p"/invocation/#{Conveyor.Bep.Replay.uuid()}")
    end

    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/invocation/not-a-uuid") end
  end
end

defmodule ConveyorWeb.InvocationLiveMetricsTest do
  use ConveyorWeb.LiveCase, async: false

  test "metrics tab renders every BuildMetrics group and tool logs", %{conn: conn} do
    id = ingest_fixture!("clean_build_and_test", context())
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/metrics")
    assert has_element?(view, "#metrics-actionSummary")
    assert has_element?(view, "#metrics-timingMetrics")
    assert has_element?(view, "#tool-logs")
    assert render(view) =~ "critical path"

    empty =
      Conveyor.Repo.insert!(%Conveyor.Invocations.Invocation{
        id: Conveyor.Bep.Replay.uuid(),
        project_id: context().project_id
      })

    {:ok, view, _} = live(conn, ~p"/invocation/#{empty.id}/metrics")
    assert render(view) =~ "nothing has arrived yet"
  end
end
