defmodule ConveyorWeb.UploadControllerTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.{Artifacts, Blobs, Invocations, Projects}
  alias Conveyor.Bep.Fixture

  @moduletag :capture_log

  setup do
    project = Projects.ensure_default_project!()

    {:ok, _, upload_key} =
      Projects.create_api_key(project, %{name: "uploader", scopes: ["upload"]})

    {:ok, _, ingest_key} =
      Projects.create_api_key(project, %{name: "ingester", scopes: ["ingest"]})

    id = ingest_fixture!("clean_build_and_test", context())
    %{project: project, upload_key: upload_key, ingest_key: ingest_key, id: id}
  end

  defp put_raw(conn, path, body, headers) do
    headers =
      if List.keymember?(headers, "content-type", 0),
        do: headers,
        else: [{"content-type", "application/octet-stream"} | headers]

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end) |> put(path, body)
  end

  test "authentication and scopes", %{conn: conn, id: id, upload_key: key, ingest_key: ingest_key} do
    path = ~p"/api/v1/invocations/#{id}/artifacts/notes.txt"

    assert %{"errors" => %{"detail" => "missing" <> _}} =
             put_raw(conn, path, "x", []) |> json_response(401)

    assert put_raw(conn, path, "x", [{"x-api-key", "garbage"}]) |> json_response(401)
    assert put_raw(conn, path, "x", [{"authorization", "Basic abc"}]) |> json_response(401)

    assert %{"errors" => %{"detail" => msg}} =
             put_raw(conn, path, "x", [{"x-api-key", ingest_key}]) |> json_response(403)

    assert msg =~ "upload scope"

    assert put_raw(conn, path, "x", [{"authorization", "Bearer " <> key}]) |> json_response(201)

    {:ok, revoked, revoked_key} =
      Projects.create_api_key(Projects.ensure_default_project!(), %{name: "r", scopes: ["upload"]})

    {:ok, _} = Projects.revoke_api_key(revoked)

    assert %{"errors" => %{"detail" => "API key revoked"}} =
             put_raw(conn, path, "x", [{"x-api-key", revoked_key}]) |> json_response(403)
  end

  test "uploads artifacts and recognises profiles", %{conn: conn, id: id, upload_key: key} do
    inv = Invocations.get!(id)
    assert inv.profile_status == "unavailable"

    body = :crypto.strong_rand_bytes(300_000)

    resp =
      put_raw(conn, ~p"/api/v1/invocations/#{id}/artifacts/command.profile.gz", body, [
        {"x-api-key", key},
        {"content-type", "application/gzip"}
      ])
      |> json_response(201)

    assert %{
             "name" => "command.profile.gz",
             "size" => 300_000,
             "digest" => digest,
             "content_type" => "application/gzip"
           } = resp

    assert digest == Blobs.digest(body)
    assert %{profile_status: "available", profile_blob: ^digest} = Invocations.get!(id)
    assert [%{name: "command.profile.gz", source: "upload"}] = Artifacts.list(inv)

    # Replacing by name, default content type from the name.
    resp =
      put_raw(conn, ~p"/api/v1/invocations/#{id}/artifacts/command.profile.gz", "v2", [
        {"x-api-key", key}
      ])
      |> json_response(201)

    assert resp["size"] == 2
    assert resp["content_type"] == "application/gzip"
    assert Invocations.get!(id).profile_blob == Blobs.digest("v2")

    # Download it back through the UI route.
    conn2 = get(build_conn(), ~p"/invocation/#{id}/artifact/command.profile.gz")
    assert response(conn2, 200) == "v2"
    assert get_resp_header(conn2, "content-type") == ["application/gzip"]

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{id}/artifact/nope")
    end

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{Ecto.UUID.generate()}/artifact/x")
    end

    :ok = Blobs.delete(Blobs.digest("v2"))

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{id}/artifact/command.profile.gz")
    end

    # The timeline fetches it from /profile with gzip passthrough.
    gz = :zlib.gzip("{\"traceEvents\":[]}")

    put_raw(conn, ~p"/api/v1/invocations/#{id}/artifacts/command.profile.gz", gz, [
      {"x-api-key", key}
    ])
    |> json_response(201)

    conn3 = get(build_conn(), ~p"/invocation/#{id}/download/profile")
    assert get_resp_header(conn3, "content-encoding") == ["gzip"]
    assert response(conn3, 200) == gz

    put_raw(conn, ~p"/api/v1/invocations/#{id}/artifacts/command.profile.json", "{}", [
      {"x-api-key", key}
    ])
    |> json_response(201)

    conn4 = get(build_conn(), ~p"/invocation/#{id}/download/profile")
    assert get_resp_header(conn4, "content-encoding") == []
    assert response(conn4, 200) == "{}"
    Conveyor.Repo.update_all(Conveyor.Invocations.Invocation, set: [profile_status: "referenced"])

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{id}/download/profile")
    end

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{Ecto.UUID.generate()}/download/profile")
    end

    Conveyor.Repo.update_all(Conveyor.Invocations.Invocation, set: [profile_status: "available"])
    :ok = Blobs.delete(Blobs.digest("{}"))

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(build_conn(), ~p"/invocation/#{id}/download/profile")
    end
  end

  test "validates names, ownership and size", %{conn: conn, id: id, upload_key: key} do
    headers = [{"x-api-key", key}]

    assert %{"errors" => %{"detail" => "artifact name" <> _}} =
             put_raw(conn, ~p"/api/v1/invocations/#{id}/artifacts/#{"..x"}", "x", headers)
             |> json_response(422)

    assert put_raw(conn, "/api/v1/invocations/#{id}/artifacts/%2E%2E", "x", headers)
           |> json_response(422)

    assert put_raw(
             conn,
             ~p"/api/v1/invocations/#{Ecto.UUID.generate()}/artifacts/a.txt",
             "x",
             headers
           )
           |> json_response(404)

    assert put_raw(conn, ~p"/api/v1/invocations/not-a-uuid/artifacts/a.txt", "x", headers)
           |> json_response(404)

    {:ok, other} = Projects.create_project(%{slug: "other", name: "Other"})
    {:ok, _, other_key} = Projects.create_api_key(other, %{name: "o", scopes: ["upload"]})

    assert put_raw(conn, ~p"/api/v1/invocations/#{id}/artifacts/a.txt", "x", [
             {"x-api-key", other_key}
           ])
           |> json_response(404)

    conf = Application.get_env(:conveyor, Conveyor.Artifacts)
    Application.put_env(:conveyor, Conveyor.Artifacts, Keyword.put(conf, :max_bytes, 10))
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Artifacts, conf) end)

    assert put_raw(
             conn,
             ~p"/api/v1/invocations/#{id}/artifacts/big.bin",
             String.duplicate("x", 11),
             headers
           )
           |> json_response(413)

    assert put_raw(
             conn,
             ~p"/api/v1/invocations/#{Ecto.UUID.generate()}/bep",
             String.duplicate("x", 11),
             headers
           )
           |> json_response(413)
  end

  test "ingests a build_event_binary_file after the fact", %{
    conn: conn,
    upload_key: key,
    id: existing
  } do
    headers = [{"x-api-key", key}]
    events = Fixture.read!(fixture("test_failure"))

    uuid =
      Enum.find_value(events, fn
        %{payload: {:started, s}} -> s.uuid
        _ -> nil
      end)

    body = events |> Fixture.encode_all() |> IO.iodata_to_binary()

    resp = put_raw(conn, ~p"/api/v1/invocations/#{uuid}/bep", body, headers) |> json_response(202)
    assert resp["invocation_id"] == uuid
    assert resp["events"] == length(events)
    assert resp["url"] =~ "/invocation/#{uuid}"

    :ok = Conveyor.IngestCase.await_worker_exit(uuid)
    assert :ok = Conveyor.Ingest.Verify.check(uuid, length(events))
    inv = Invocations.get!(uuid)
    assert inv.status == "failed"
    assert inv.tests_failed > 0
    assert inv.api_key_id != nil

    assert %{"errors" => %{"detail" => "invocation " <> _}} =
             put_raw(conn, ~p"/api/v1/invocations/#{uuid}/bep", body, headers)
             |> json_response(409)

    assert put_raw(conn, ~p"/api/v1/invocations/#{existing}/bep", body, headers)
           |> json_response(409)

    assert %{"errors" => %{"detail" => "the file belongs" <> _}} =
             put_raw(conn, ~p"/api/v1/invocations/#{Ecto.UUID.generate()}/bep", body, headers)
             |> json_response(422)

    assert put_raw(conn, ~p"/api/v1/invocations/not-a-uuid/bep", body, headers)
           |> json_response(422)

    assert put_raw(conn, ~p"/api/v1/invocations/#{Ecto.UUID.generate()}/bep", "", headers)
           |> json_response(422)

    assert put_raw(
             conn,
             ~p"/api/v1/invocations/#{Ecto.UUID.generate()}/bep",
             <<5, 1, 2, 3, 4, 5, 200>>,
             headers
           )
           |> json_response(422)
  end

  defp fixture(name), do: Conveyor.GrpcCase.fixture(name)
end
