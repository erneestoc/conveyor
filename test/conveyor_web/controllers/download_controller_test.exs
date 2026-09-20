defmodule ConveyorWeb.DownloadControllerTest do
  use ConveyorWeb.LiveCase, async: false

  setup do
    %{id: ingest_fixture!("test_failure", context())}
  end

  test "streams a profile from a one-shot blob store without reading it twice", %{
    conn: conn,
    id: id
  } do
    prev = Application.get_env(:conveyor, Conveyor.Blobs)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Blobs, prev) end)

    Application.put_env(:conveyor, Conveyor.Blobs,
      adapter: Conveyor.Blobs.OneShot,
      opts: [dir: prev[:dir]]
    )

    inv = Conveyor.Invocations.get!(id)
    gz = :zlib.gzip("{\"traceEvents\":[]}")

    # Typed by name (an upload or a fetch): the header comes from the content type.
    {:ok, blob} = Conveyor.Blobs.put(gz, content_type: "application/gzip")
    :ok = Conveyor.Artifacts.profile_available(inv, blob)
    resp = get(conn, ~p"/invocation/#{id}/download/profile")
    assert get_resp_header(resp, "content-encoding") == ["gzip"]
    assert response(resp, 200) == gz

    # Untyped (a CAS sink upload): the magic number is read through a separate stream.
    {:ok, untyped} = Conveyor.Blobs.put(gz <> "x", content_type: nil)
    :ok = Conveyor.Artifacts.profile_available(Conveyor.Invocations.get!(id), untyped)
    resp = get(conn, ~p"/invocation/#{id}/download/profile")
    assert get_resp_header(resp, "content-encoding") == ["gzip"]
    assert response(resp, 200) == gz <> "x"

    {:ok, json} = Conveyor.Blobs.put("{}", content_type: nil)
    :ok = Conveyor.Artifacts.profile_available(Conveyor.Invocations.get!(id), json)
    resp = get(conn, ~p"/invocation/#{id}/download/profile")
    assert get_resp_header(resp, "content-encoding") == []
    assert response(resp, 200) == "{}"
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
