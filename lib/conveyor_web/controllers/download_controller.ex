defmodule ConveyorWeb.DownloadController do
  @moduledoc "Raw downloads of an invocation: the build log and the BEP event stream."
  use ConveyorWeb, :controller

  alias Conveyor.Bep.Fixture
  alias Conveyor.Invocations

  def show(conn, %{"id" => id, "kind" => kind}) when kind in ["log", "events"] do
    inv = Invocations.get(id) || raise ConveyorWeb.NotFoundError, "no invocation #{id}"

    case kind do
      "log" ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{inv.id}.log"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, Invocations.log(inv))

      "events" ->
        body =
          inv |> Invocations.raw_frames() |> Enum.map(&[Fixture.encode_varint(byte_size(&1)), &1])

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{inv.id}.bep"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, body)
    end
  end

  def show(_conn, _params), do: raise(ConveyorWeb.NotFoundError, "unknown download")
end
