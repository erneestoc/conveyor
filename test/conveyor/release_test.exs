defmodule Conveyor.ReleaseTest do
  use ExUnit.Case, async: true

  alias Conveyor.Release

  test "database ssl is off unless asked for" do
    assert Release.database_ssl(%{}) == false
    assert Release.database_ssl(%{"DATABASE_SSL" => "false"}) == false
  end

  test "database ssl verifies the host against a bundle or the OS trust store" do
    env = %{"DATABASE_SSL" => "true", "DATABASE_URL" => "ecto://u:p@db.internal:5432/conveyor"}
    opts = Release.database_ssl(env)
    assert opts[:verify] == :verify_peer
    assert opts[:server_name_indication] == ~c"db.internal"
    assert is_list(opts[:cacerts]) and opts[:cacerts] != []
    refute Keyword.has_key?(opts, :cacertfile)

    opts = Release.database_ssl(Map.put(env, "DATABASE_SSL_CA", "/etc/conveyor/rds-ca.pem"))
    assert opts[:cacertfile] == "/etc/conveyor/rds-ca.pem"
    refute Keyword.has_key?(opts, :cacerts)

    # No host in the URL: SNI is disabled rather than crashing at boot.
    assert Release.database_ssl(%{"DATABASE_SSL" => "1"})[:server_name_indication] == :disable
  end

  test "replay connect options carry TLS credentials only when asked" do
    assert Conveyor.Bep.Replay.connect_opts("h", false) == [adapter: GRPC.Client.Adapters.Mint]
    opts = Conveyor.Bep.Replay.connect_opts("bes.example.com", true)
    assert %GRPC.Credential{ssl: ssl} = opts[:cred]
    assert ssl[:server_name_indication] == ~c"bes.example.com" and ssl[:verify] == :verify_peer
  end
end
