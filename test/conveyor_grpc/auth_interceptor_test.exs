defmodule Conveyor.Grpc.AuthInterceptorTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Grpc.AuthInterceptor
  alias Conveyor.Ingest.Context
  alias Conveyor.Projects

  setup do
    Projects.ApiKeyCache.clear()
    previous = Application.get_env(:conveyor, Conveyor.Ingest)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Ingest, previous) end)
    {:ok, project} = Projects.create_project(%{slug: "auth", name: "Auth"})

    {:ok, key, plaintext} =
      Projects.create_api_key(project, %{name: "ci", default_tags: %{"ci" => "true"}})

    %{project: project, key: key, plaintext: plaintext, previous: previous}
  end

  test "api key mode maps keys to their project", %{
    project: project,
    key: key,
    plaintext: plaintext
  } do
    assert {:ok, %Context{project_id: pid, api_key_id: kid, api_key_tags: %{"ci" => "true"}}} =
             AuthInterceptor.authenticate(%{"x-api-key" => plaintext})

    assert pid == project.id and kid == key.id

    assert {:ok, %Context{}} =
             AuthInterceptor.authenticate(%{"authorization" => "Bearer " <> plaintext})

    assert {:ok, %Context{}} =
             AuthInterceptor.authenticate(%{"authorization" => "bearer " <> plaintext})

    assert {:error, :unauthenticated, msg} = AuthInterceptor.authenticate(%{})
    assert msg =~ "--bes_header"

    assert {:error, :unauthenticated, _} =
             AuthInterceptor.authenticate(%{"x-api-key" => "garbage"})

    assert {:error, :unauthenticated, _} =
             AuthInterceptor.authenticate(%{"x-api-key" => "conveyor_zzzzzzzz_nope"})

    {:ok, _} = Projects.revoke_api_key(key)

    assert {:error, :permission_denied, _} =
             AuthInterceptor.authenticate(%{"x-api-key" => plaintext})

    {:ok, _expired, expired_plaintext} =
      Projects.create_api_key(project, %{
        name: "e",
        expires_at: DateTime.add(DateTime.utc_now(), -1)
      })

    assert {:error, :permission_denied, _} =
             AuthInterceptor.authenticate(%{"x-api-key" => expired_plaintext})

    {:ok, _read, read_plaintext} =
      Projects.create_api_key(project, %{name: "r", scopes: ["read"]})

    assert {:error, :permission_denied, msg} =
             AuthInterceptor.authenticate(%{"x-api-key" => read_plaintext})

    assert msg =~ "scope"
  end

  test "scopes depend on the service", %{project: project} do
    {:ok, _, upload_key} = Projects.create_api_key(project, %{name: "u", scopes: ["upload"]})
    assert AuthInterceptor.scopes_for("google.devtools.build.v1.PublishBuildEvent") == ["ingest"]
    assert AuthInterceptor.scopes_for("google.bytestream.ByteStream") == ["ingest", "upload"]

    assert {:error, :permission_denied, msg} =
             AuthInterceptor.authenticate(%{"x-api-key" => upload_key})

    assert msg =~ "ingest scope"

    assert {:ok, %{project_id: id}} =
             AuthInterceptor.authenticate(%{"x-api-key" => upload_key}, ["ingest", "upload"])

    assert id == project.id
  end

  test "open mode maps everything to the default project", %{previous: previous} do
    Application.put_env(:conveyor, Conveyor.Ingest, Keyword.put(previous, :auth, :none))
    :persistent_term.erase({AuthInterceptor, :default_project})

    assert {:ok, %Context{project_slug: "default", api_key_id: nil}} =
             AuthInterceptor.authenticate(%{})

    assert {:ok, %Context{project_slug: "default"}} =
             AuthInterceptor.authenticate(%{"x-api-key" => "ignored"})
  end

  test "the interceptor attaches the context or raises", %{plaintext: plaintext} do
    stream = %GRPC.Server.Stream{
      adapter: Conveyor.Grpc.AuthInterceptorTest.FakeAdapter,
      payload: %{headers: %{"x-api-key" => plaintext}},
      local: nil
    }

    next = fn req, stream -> {req, stream.local.ctx} end
    assert {:req, %Context{}} = AuthInterceptor.call(:req, stream, next, AuthInterceptor.init([]))

    bad = %{stream | payload: %{headers: %{}}}

    assert_raise GRPC.RPCError, ~r/missing API key/, fn ->
      AuthInterceptor.call(:req, bad, next, [])
    end
  end

  defmodule FakeAdapter do
    def get_headers(%{headers: headers}), do: headers
  end
end
