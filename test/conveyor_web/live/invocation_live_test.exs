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

  test "timeline tab shows hints, then the profile timeline and summary", %{conn: conn, ok_id: id} do
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/timeline")
    assert has_element?(view, "#timeline-tab[data-profile=unavailable]")
    assert has_element?(view, "#profile-hint", "Upload it with")
    refute has_element?(view, "#profile-timeline")
    assert has_element?(view, "#timeline")

    fixture =
      Path.join([
        File.cwd!(),
        "test/fixtures/blobs",
        "c9fb9e145e0fbb8955f0a0f93e7cfa750e3ab9e6e15387e5caacf811cfa7ec86"
      ])

    {:ok, blob} = Conveyor.Blobs.put(File.read!(fixture), content_type: "application/gzip")
    inv = Conveyor.Invocations.get!(id)
    :ok = Conveyor.Artifacts.profile_available(inv, blob)

    assert :ok =
             Conveyor.Workers.ProfileSummary.perform(%Oban.Job{args: %{"invocation_id" => id}})

    # The broadcast from the summary job reaches the open view.
    assert render(view) =~ "profile-summary"
    assert has_element?(view, "#profile-timeline[data-url='/invocation/#{id}/download/profile']")
    assert has_element?(view, "#profile-summary", "Launch Blaze")
    assert has_element?(view, "#profile-summary", "Genrule")
    refute has_element?(view, "#profile-hint")

    for status <- ~w(referenced failed none) do
      Conveyor.Repo.update_all(Conveyor.Invocations.Invocation, set: [profile_status: status])
      {:ok, view, _} = live(conn, ~p"/invocation/#{id}/timeline")
      assert has_element?(view, "#profile-hint")
    end

    Conveyor.Repo.update_all(Conveyor.Invocations.Invocation,
      set: [profile_status: "unavailable", profile_uri: "bytestream://x/blobs/#{blob.digest}/1"]
    )

    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/timeline")
    assert has_element?(view, "#profile-hint", "not allowed to contact")
  end

  test "tests tab fetches test.log and test.xml from the blob store", %{
    conn: conn,
    ctx: ctx,
    ok_id: ok_id
  } do
    for digest <-
          ~w(b5a25a43f146a8201e71729b95aec18cbebc3d47a61be6f6f11523d46d0d755c 94a90e1beb50bfb773239210a2b21dfc0b3fbb709b3fce460f1886fc891868bc) do
      {:ok, _} =
        Conveyor.Blobs.put(File.read!(Path.join([File.cwd!(), "test/fixtures/blobs", digest])))
    end

    id = ingest_fixture!("remote_cache_upload", ctx)
    {:ok, view, _} = live(conn, ~p"/invocation/#{id}/tests")
    row = "#test-#{:erlang.phash2("//app:pass_test")}"

    view |> element("#{row} button[phx-value-name='test.log']") |> render_click()
    assert render_async(view) =~ "pass_test: ok"
    assert has_element?(view, "#test-file-log")

    view |> element("#{row} button[phx-value-name='test.xml']") |> render_click()
    render_async(view)
    assert has_element?(view, "#test-file-junit tr[data-status=passed] td", "app/pass_test")
    assert has_element?(view, "#test-file-junit details")

    view |> element("#close-test-file") |> render_click()
    refute has_element?(view, "#test-file")

    # Files Bazel kept locally cannot be fetched; the panel explains why.
    {:ok, view, _} = live(conn, ~p"/invocation/#{ok_id}/tests")
    view |> element("#{row} button[phx-value-name='test.log']") |> render_click()
    assert render_async(view) =~ "kept this file on the machine"
    assert has_element?(view, "#test-file-error")

    # Unknown attempts are reported, not crashed on.
    assert render_click(view, "view_test_file", %{
             "label" => "//nope",
             "config" => "",
             "run" => "1",
             "shard" => "1",
             "attempt" => "1",
             "name" => "test.log"
           }) =~ "not attached"
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
