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

  @doc "Serves a named artifact (uploaded or fetched) from the blob store."
  def artifact(conn, %{"id" => id, "name" => name}) do
    inv = Invocations.get(id) || raise ConveyorWeb.NotFoundError, "no invocation #{id}"

    artifact =
      Conveyor.Artifacts.get(inv, name) || raise ConveyorWeb.NotFoundError, "no artifact #{name}"

    case Conveyor.Blobs.stream(artifact.digest) do
      {:ok, chunks} ->
        conn =
          conn
          |> put_resp_content_type(artifact.content_type || "application/octet-stream", nil)
          |> put_resp_header("content-length", Integer.to_string(artifact.size))
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_chunked(200)

        Enum.reduce_while(chunks, conn, fn data, conn ->
          case chunk(conn, data) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)

      {:error, _} ->
        raise ConveyorWeb.NotFoundError, "artifact #{name} is no longer in the blob store"
    end
  end
end
