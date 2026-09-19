defmodule Conveyor.AwsTest do
  use ExUnit.Case, async: false

  alias Conveyor.Aws

  setup_all do
    %{endpoint: Conveyor.FakeAws.start()}
  end

  @env ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION)

  setup %{endpoint: endpoint} do
    previous = Application.get_env(:conveyor, Conveyor.Aws)
    Application.put_env(:conveyor, Conveyor.Aws, imds_endpoint: endpoint)
    Aws.reset()
    # The developer's own AWS environment must not leak into these tests.
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Application.put_env(:conveyor, Conveyor.Aws, previous || [])

      Enum.each(saved, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

      Aws.reset()
    end)

    :ok
  end

  test "explicit credentials win, otherwise the instance role is used and cached" do
    assert {:ok, %{access_key_id: "AK", secret_access_key: "SK", session_token: nil}} =
             Aws.credentials(access_key_id: "AK", secret_access_key: "SK")

    assert {:ok,
            %{
              access_key_id: "ASIAROLE",
              secret_access_key: "rolesecret",
              session_token: "roletoken"
            }} = Aws.credentials()

    assert {:ok, %{access_key_id: "ASIAROLE"}} = Aws.imds_credentials()
    assert Aws.region() == "eu-central-1"
    assert Aws.region(region: "us-west-2") == "us-west-2"
    assert {:ok, "10.0.0.7"} = Aws.imds_private_ip()
  end

  test "describes instances by tag and extracts instance private IPs", %{endpoint: endpoint} do
    assert {:ok, ["10.0.0.7", "10.0.0.8"]} =
             Aws.describe_instances_by_tag("conveyor", "prod", endpoint: endpoint)

    assert {:ok, ips} =
             Aws.describe_instances_by_tag("conveyor", "prod",
               endpoint: endpoint,
               region: "us-east-1",
               access_key_id: "AK",
               secret_access_key: "SK"
             )

    assert ips == ["10.0.0.7", "10.0.0.8"]
    assert Aws.private_ips("not xml") == []
  end

  test "reports IMDS and EC2 failures" do
    Application.put_env(:conveyor, Conveyor.Aws, imds_endpoint: "http://127.0.0.1:1")
    Aws.reset()
    assert {:error, {:imds, _}} = Aws.credentials()
    assert Aws.region() == nil
    assert {:error, _} = Aws.imds_private_ip()

    assert {:error, :no_region} =
             Aws.describe_instances_by_tag("t", "v", access_key_id: "AK", secret_access_key: "SK")

    assert {:error, _} =
             Aws.describe_instances_by_tag("t", "v",
               endpoint: "http://127.0.0.1:1",
               region: "r",
               access_key_id: "AK",
               secret_access_key: "SK"
             )
  end
end
