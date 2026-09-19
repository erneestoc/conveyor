defmodule Conveyor.FakeAws do
  @moduledoc "Fake IMDSv2 and EC2 DescribeInstances endpoints for tests."
  import Plug.Conn
  @behaviour Plug

  def start do
    port = Conveyor.GrpcCase.free_port()
    {:ok, _} = Bandit.start_link(plug: __MODULE__, port: port, ip: {127, 0, 0, 1})
    "http://127.0.0.1:#{port}"
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "PUT", path_info: ["latest", "api", "token"]} = conn, _),
    do: send_resp(conn, 200, "imds-token")

  def call(%{path_info: ["latest", "meta-data" | rest]} = conn, _) do
    case get_req_header(conn, "x-aws-ec2-metadata-token") do
      ["imds-token"] ->
        case rest do
          ["iam", "security-credentials"] ->
            send_resp(conn, 200, "conveyor-role\n")

          ["iam", "security-credentials", "conveyor-role"] ->
            exp = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

            send_resp(
              conn,
              200,
              Jason.encode!(%{
                "AccessKeyId" => "ASIAROLE",
                "SecretAccessKey" => "rolesecret",
                "Token" => "roletoken",
                "Expiration" => exp
              })
            )

          ["placement", "region"] ->
            send_resp(conn, 200, "eu-central-1")

          ["local-ipv4"] ->
            send_resp(conn, 200, "10.0.0.7")

          _ ->
            send_resp(conn, 404, "")
        end

      _ ->
        send_resp(conn, 401, "")
    end
  end

  def call(%{method: "POST", path_info: []} = conn, _) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)
    [auth] = get_req_header(conn, "authorization")

    if params["Action"] == "DescribeInstances" and auth =~ "/ec2/aws4_request" do
      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, describe_xml(params["Filter.1.Value.1"]))
    else
      send_resp(conn, 400, "bad request")
    end
  end

  def call(conn, _), do: send_resp(conn, 404, "")

  defp describe_xml(value) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
      <reservationSet><item><instancesSet>
        <item><instanceId>i-1</instanceId><privateIpAddress>10.0.0.7</privateIpAddress>
          <networkInterfaceSet><item><privateIpAddress>10.0.0.7</privateIpAddress><privateIpAddressesSet><item><privateIpAddress>10.0.0.99</privateIpAddress></item></privateIpAddressesSet></item></networkInterfaceSet>
          <tagSet><item><key>conveyor</key><value>#{value}</value></item></tagSet></item>
        <item><instanceId>i-2</instanceId><privateIpAddress>10.0.0.8</privateIpAddress></item>
      </instancesSet></item></reservationSet>
    </DescribeInstancesResponse>
    """
  end
end
