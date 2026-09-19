defmodule ConveyorWeb.DownloadController do
  @moduledoc "Raw downloads of an invocation: the build log and the BEP event stream."
  use ConveyorWeb, :controller

  alias Conveyor.Bep.Fixture
  alias Conveyor.Invocations

  def show(conn, %{"id" => id, "kind" => "profile"}), do: profile(conn, %{"id" => id})

  def show(conn, %{"id" => id, "kind" => kind}) when kind in ["log", "events"] do
    inv = ConveyorWeb.Auth.invocation!(conn, id)

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

  @doc """
  Serves the JSON profile for the timeline. Gzipped profiles are sent as-is with
  `Content-Encoding: gzip`, so the browser (and the Web Worker's `fetch`) sees JSON.
  """
  def profile(conn, %{"id" => id}) do
    inv = ConveyorWeb.Auth.invocation!(conn, id)

    if inv.profile_status != "available" or is_nil(inv.profile_blob),
      do: raise(ConveyorWeb.NotFoundError, "profile not available")

    case Conveyor.Blobs.stream(inv.profile_blob, chunk_size: 256 * 1024) do
      {:ok, chunks} ->
        {chunks, conn} = maybe_gzip_encoding(chunks, conn)

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_chunked(200)
        |> send_chunks(chunks)

      {:error, _} ->
        raise ConveyorWeb.NotFoundError, "profile is no longer in the blob store"
    end
  end

  # Peeks at the first chunk: a gzip magic number means we can pass the bytes through
  # with a content-encoding header instead of inflating them on the server.
  defp maybe_gzip_encoding(chunks, conn) do
    case Enum.take(chunks, 1) do
      [<<0x1F, 0x8B, _::binary>>] -> {chunks, put_resp_header(conn, "content-encoding", "gzip")}
      _ -> {chunks, conn}
    end
  end

  defp send_chunks(conn, chunks) do
    Enum.reduce_while(chunks, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  @doc "Serves a named artifact (uploaded or fetched) from the blob store."
  # The content type is sanitized by safe_content_type/1 and served as an attachment.
  # sobelow_skip ["XSS.ContentType"]
  def artifact(conn, %{"id" => id, "name" => name}) do
    inv = ConveyorWeb.Auth.invocation!(conn, id)

    artifact =
      Conveyor.Artifacts.get(inv, name) || raise ConveyorWeb.NotFoundError, "no artifact #{name}"

    case Conveyor.Blobs.stream(artifact.digest) do
      {:ok, chunks} ->
        conn =
          conn
          |> put_resp_content_type(safe_content_type(artifact.content_type), nil)
          |> put_resp_header("content-length", Integer.to_string(artifact.size))
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_chunked(200)

        send_chunks(conn, chunks)

      {:error, _} ->
        raise ConveyorWeb.NotFoundError, "artifact #{name} is no longer in the blob store"
    end
  end

  # Artifact content types are client-supplied at upload time: serve only well-formed,
  # non-executable media types (never text/html or scripts) as attachments.
  @doc false
  def safe_content_type(type) when is_binary(type) do
    cond do
      not Regex.match?(~r{^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$}i, type) ->
        "application/octet-stream"

      String.downcase(type) in ["text/html", "application/xhtml+xml", "image/svg+xml"] ->
        "application/octet-stream"

      String.contains?(String.downcase(type), ["javascript", "ecmascript"]) ->
        "application/octet-stream"

      true ->
        String.downcase(type)
    end
  end

  def safe_content_type(_), do: "application/octet-stream"
end
