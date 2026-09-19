defmodule ConveyorWeb.DownloadControllerTest do
  use ConveyorWeb.LiveCase, async: false

  setup do
    %{id: ingest_fixture!("test_failure", context())}
  end

  test "lists artifacts on the details tab", %{conn: conn, id: id} do
    {:ok, view, html} = live(conn, ~p"/invocation/#{id}/details")
    assert html =~ "None. Upload with"
    {:ok, blob} = Conveyor.Blobs.put("notes")
    Conveyor.Artifacts.attach(id, "notes.txt", blob, "upload")
    send(view.pid, {:artifacts_changed, id})
    assert render(view) =~ "notes.txt"
    assert has_element?(view, "#profile-status", "unavailable")
  end

  test "downloads the log and the raw events", %{conn: conn, id: id} do
    conn = get(conn, ~p"/invocation/#{id}/download/log")
    assert response_content_type(conn, :text) =~ "text/plain"
    body = response(conn, 200)
    assert body =~ "FAIL"
    assert get_resp_header(conn, "x-log-bytes") == [Integer.to_string(byte_size(body))]

    conn = get(build_conn(), ~p"/invocation/#{id}/download/events")
    assert response(conn, 200) |> Conveyor.Bep.Fixture.decode_all!() |> length() > 10

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{id}/download/nope")
    end

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{Conveyor.Bep.Replay.uuid()}/download/log")
    end
  end
end
