defmodule Conveyor.Artifacts.BytestreamClientTest do
  use Conveyor.DataCase, async: false

  @moduletag :capture_log

  alias Conveyor.Artifacts.{BytestreamClient, Resource}
  alias Conveyor.{Blobs, FakeCache}

  @hash String.duplicate("ab", 32)

  test "resolves the dial target, TLS options and metadata from the endpoint config" do
    {:ok, ref} = Resource.parse_uri("bytestream://cas.internal/main/blobs/#{@hash}/7")
    assert BytestreamClient.target(%{}, ref) == {"cas.internal", 80}
    assert BytestreamClient.target(%{"tls" => true}, ref) == {"cas.internal", 443}

    assert BytestreamClient.target(%{"endpoint" => "grpcs://10.0.0.5:8980", "tls" => true}, ref) ==
             {"10.0.0.5", 8980}

    assert BytestreamClient.target(
             %{"endpoint" => "cas-proxy", "tls" => %{"mode" => "plaintext"}},
             ref
           ) == {"cas-proxy", 80}

    assert BytestreamClient.tls_mode(%{}) == "plaintext"
    assert BytestreamClient.tls_mode(%{"tls" => true}) == "system_roots"
    assert BytestreamClient.tls_mode(%{"tls" => %{"mode" => "mtls"}}) == "mtls"
    assert BytestreamClient.tls_mode(%{"tls" => %{"mode" => "weird"}}) == "plaintext"

    assert {:ok, nil} = BytestreamClient.ssl_options(%{}, "h")
    assert {:ok, opts} = BytestreamClient.ssl_options(%{"tls" => true}, "h")
    assert opts[:verify] == :verify_peer and is_list(opts[:cacerts])

    assert {:error, {:tls_file_missing, "ca_file", nil}} =
             BytestreamClient.ssl_options(%{"tls" => %{"mode" => "custom_ca"}}, "h")

    assert {:error, {:tls_file_missing, "ca_file", "/nope"}} =
             BytestreamClient.ssl_options(
               %{"tls" => %{"mode" => "mtls", "ca_file" => "/nope"}},
               "h"
             )

    assert BytestreamClient.metadata(%{"headers" => %{"x-api-key" => "k"}, "bearer_token" => "t"}) ==
             %{"x-api-key" => "k", "authorization" => "Bearer t"}

    assert BytestreamClient.metadata(%{}) == %{}
  end

  test "fetches through an endpoint override with a bearer token" do
    port = FakeCache.start()
    data = "override #{System.unique_integer()}"
    resource = FakeCache.serve(data)
    {:ok, ref} = Resource.parse_uri("bytestream://cas.internal/#{resource}")

    endpoint = %{
      "endpoint" => "grpc://127.0.0.1:#{port}",
      "tls" => false,
      "bearer_token" => "s3cret"
    }

    project = Conveyor.Projects.ensure_default_project!()
    assert {:ok, blob} = BytestreamClient.fetch(endpoint, ref, project_id: project.id)
    assert {:ok, ^data} = Blobs.read(project.id, blob.digest)
    assert FakeCache.headers()["authorization"] == "Bearer s3cret"
  end

  test "mTLS with a private CA and a client certificate (NativeLink-style listener)" do
    dir = Path.join(System.tmp_dir!(), "conveyor-mtls-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    certs = FakeCache.test_certs(dir)

    port =
      FakeCache.start(
        tls: [
          certfile: String.to_charlist(certs.server_cert),
          keyfile: String.to_charlist(certs.server_key),
          cacertfile: String.to_charlist(certs.client_ca)
        ]
      )

    data = "mtls #{System.unique_integer()}"
    resource = FakeCache.serve(data)
    {:ok, ref} = Resource.parse_uri("bytestream://127.0.0.1:#{port}/#{resource}")

    mtls = %{
      "tls" => %{
        "mode" => "mtls",
        "ca_file" => certs.server_ca,
        "client_cert_file" => certs.client_cert,
        "client_key_file" => certs.client_key
      }
    }

    project = Conveyor.Projects.ensure_default_project!()
    assert {:ok, blob} = BytestreamClient.fetch(mtls, ref, project_id: project.id)
    assert {:ok, ^data} = Blobs.read(project.id, blob.digest)
    :ok = Blobs.delete(project.id, blob.digest)

    # Without a client certificate the listener refuses the handshake; plaintext cannot talk TLS.
    assert {:error, _} =
             BytestreamClient.fetch(
               %{"tls" => %{"mode" => "custom_ca", "ca_file" => certs.server_ca}},
               ref,
               project_id: project.id
             )

    assert {:error, _} = BytestreamClient.fetch(%{"tls" => false}, ref, project_id: project.id)
  end

  test "project endpoint configuration normalizes the connection model" do
    project = Conveyor.Projects.ensure_default_project!()

    {:ok, p} =
      Conveyor.Projects.put_cache_endpoint(project, "cas.rbe.internal", %{
        "headers" => %{"x-buildbuddy-api-key" => "k", "" => "x"},
        "tls" => %{
          "mode" => "mtls",
          "ca_file" => "/s/ca.crt",
          "client_cert_file" => "/s/c.crt",
          "client_key_file" => "/s/c.key",
          "junk" => "1"
        },
        "endpoint" => "grpcs://cas.rbe.internal:443",
        "bearer_token" => ""
      })

    assert %{
             "headers" => %{"x-buildbuddy-api-key" => "k"},
             "tls" => %{
               "mode" => "mtls",
               "ca_file" => "/s/ca.crt",
               "client_cert_file" => "/s/c.crt",
               "client_key_file" => "/s/c.key"
             },
             "endpoint" => "grpcs://cas.rbe.internal:443"
           } = Conveyor.Projects.cache_endpoints(p)["cas.rbe.internal"]

    {:ok, p} =
      Conveyor.Projects.put_cache_endpoint(p, "plain", %{
        "tls" => %{"mode" => "plaintext"},
        "bearer_token" => "tok"
      })

    assert %{"tls" => false, "bearer_token" => "tok"} =
             Conveyor.Projects.cache_endpoints(p)["plain"]

    {:ok, p} =
      Conveyor.Projects.put_cache_endpoint(p, "sys", %{"tls" => %{"mode" => "system_roots"}})

    assert %{"tls" => true} = Conveyor.Projects.cache_endpoints(p)["sys"]

    assert {:error, :invalid_endpoint} =
             Conveyor.Projects.put_cache_endpoint(p, "sys", %{"endpoint" => "http://x/y"})
  end
end
