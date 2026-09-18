defmodule ConveyorWeb.DownloadControllerTest do
  use ConveyorWeb.LiveCase, async: false

  setup do
    %{id: ingest_fixture!("test_failure", context())}
  end

  test "downloads the log and the raw events", %{conn: conn, id: id} do
    conn = get(conn, ~p"/invocation/#{id}/download/log")
    assert response_content_type(conn, :text) =~ "text/plain"
    assert response(conn, 200) =~ "FAIL"

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
