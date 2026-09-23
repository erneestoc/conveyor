defmodule ConveyorWeb.UploadController do
  @moduledoc """
  HTTP upload API, authenticated with an `upload`-scoped key:

    * `PUT /api/v1/invocations/:id/artifacts/:name` — attach a file to a build. The body
      is the raw file. Profiles (`--profile`, `*.profile.gz`) are summarized and execution
      logs (`--execution_log_compact_file`, any name containing `exec log`) are parsed.
    * `PUT /api/v1/invocations/:id/bep` — ingest a `--build_event_binary_file` after
      the fact (air-gapped CI, or a build that ran with no BES connection).
  """
  use ConveyorWeb, :controller

  alias Conveyor.Artifacts
  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.Blobs
  alias Conveyor.Ingest
  alias Conveyor.Invocations
  alias Google.Devtools.Build.V1, as: V1

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/

  def artifact(conn, %{"id" => id, "name" => name}) do
    key = conn.assigns.api_key

    with {:ok, inv} <- owned_invocation(id, key),
         :ok <- valid_name(name),
         {:ok, blob} <- store_body(conn, name),
         {:ok, artifact} <- Artifacts.attach(inv, name, blob, "upload") do
      if Artifacts.profile_name?(name), do: Artifacts.profile_available(inv, blob, name)
      if Conveyor.ExecLog.name?(name), do: Conveyor.ExecLog.available(inv, blob)

      Conveyor.Audit.log(key, "upload.artifact",
        subject: {"invocation", inv.id},
        project_id: inv.project_id,
        ip: Conveyor.Audit.ip(conn),
        metadata: %{"name" => name, "size" => blob.size}
      )

      conn
      |> put_status(201)
      |> json(%{
        invocation_id: inv.id,
        name: artifact.name,
        digest: artifact.digest,
        size: artifact.size,
        content_type: artifact.content_type
      })
    else
      {:error, :blob_gone} ->
        error(conn, 503, "the blob was removed before it could be attached; retry")

      {:error, status, message} ->
        error(conn, status, message)
    end
  end

  def bep(conn, %{"id" => id}) do
    key = conn.assigns.api_key

    with {:ok, uuid} <- cast_uuid(id),
         :ok <- not_already_finished(uuid, key),
         {:ok, body} <- read_all(conn),
         {:ok, events} <- decode_events(body),
         :ok <- ids_match(uuid, events),
         {:ok, count} <- ingest(key, uuid, events) do
      Conveyor.Audit.log(key, "upload.bep",
        subject: {"invocation", uuid},
        project_id: key.project_id,
        ip: Conveyor.Audit.ip(conn),
        metadata: %{"events" => count}
      )

      conn
      |> put_status(202)
      |> json(%{invocation_id: uuid, events: count, url: url(~p"/invocation/#{uuid}")})
    else
      {:error, status, message} -> error(conn, status, message)
    end
  end

  defp owned_invocation(id, key) do
    case Invocations.get(id) do
      %{project_id: pid} = inv when pid == key.project_id -> {:ok, inv}
      _ -> {:error, 404, "no invocation #{id} in project #{key.project.slug}"}
    end
  end

  defp valid_name(name) do
    if Regex.match?(@name_re, name) and name not in [".", ".."],
      do: :ok,
      else: {:error, 422, "artifact name must match #{inspect(@name_re.source)}"}
  end

  defp store_body(conn, name) do
    content_type =
      case get_req_header(conn, "content-type") do
        [ct | _] when ct not in ["", "application/octet-stream"] ->
          ct |> String.split(";") |> hd()

        _ ->
          Artifacts.content_type(name)
      end

    case Blobs.put(conn.assigns.api_key.project_id, body_stream(conn),
           source: "upload",
           content_type: content_type
         ) do
      {:ok, blob} -> {:ok, blob}
      {:error, reason} -> {:error, 500, "could not store artifact: #{inspect(reason)}"}
    end
  catch
    {:body_error, :too_large} -> {:error, 413, "artifact exceeds the size limit"}
    {:body_error, reason} -> {:error, 400, "could not read body: #{inspect(reason)}"}
  end

  # Streams the request body in chunks, enforcing the configured size limit.
  defp body_stream(conn) do
    max = Artifacts.config(:max_bytes, 512 * 1024 * 1024)

    Stream.resource(
      fn -> {conn, 0} end,
      fn
        {:done, _} ->
          {:halt, nil}

        {conn, total} ->
          case read_body(conn, length: 1_000_000, read_length: 256 * 1024) do
            {:ok, data, _conn} -> check_size(data, total, max, :done)
            {:more, data, conn} -> check_size(data, total, max, conn)
            {:error, reason} -> throw({:body_error, reason})
          end
      end,
      fn _ -> :ok end
    )
  end

  defp check_size(data, total, max, next) do
    if total + byte_size(data) > max,
      do: throw({:body_error, :too_large}),
      else: {[data], {next, total + byte_size(data)}}
  end

  defp read_all(conn) do
    {:ok, body_stream(conn) |> Enum.to_list() |> IO.iodata_to_binary()}
  catch
    {:body_error, :too_large} -> {:error, 413, "file exceeds the size limit"}
    {:body_error, reason} -> {:error, 400, "could not read body: #{inspect(reason)}"}
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, 422, "invocation id must be a UUID"}
    end
  end

  # An id that belongs to another project is "not found" for this key: it is neither
  # reported as finished nor appended to.
  defp not_already_finished(uuid, key) do
    case Invocations.get(uuid) do
      %{project_id: pid} when pid != key.project_id ->
        {:error, 404, "no invocation #{uuid} in project #{key.project.slug}"}

      %{stream_finished: true} ->
        {:error, 409, "invocation #{uuid} already has a complete event stream"}

      _ ->
        :ok
    end
  end

  defp decode_events(body) do
    case Fixture.decode_all!(body) do
      [] -> {:error, 422, "no build events in body"}
      events -> {:ok, events}
    end
  rescue
    _ -> {:error, 422, "body is not a build_event_binary_file"}
  end

  defp ids_match(uuid, events) do
    case Enum.find_value(events, fn
           %{payload: {:started, %{uuid: u}}} -> u
           _ -> nil
         end) do
      nil -> :ok
      ^uuid -> :ok
      other -> {:error, 422, "the file belongs to invocation #{other}, not #{uuid}"}
    end
  end

  defp ingest(key, uuid, events) do
    ctx = %Ingest.Context{
      project_id: key.project_id,
      project_slug: key.project.slug,
      api_key_id: key.id,
      api_key_tags: key.default_tags
    }

    stream_id = %V1.StreamId{build_id: uuid, invocation_id: uuid, component: :TOOL}

    marker =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    all =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} -> Replay.ordered_event(stream_id, seq, event) end)
      |> Kernel.++([Replay.ordered_event(stream_id, length(events) + 1, marker)])

    Enum.reduce_while(all, {:ok, length(events)}, fn obe, acc ->
      case Ingest.push_sync(ctx, obe, 30_000) do
        :ok ->
          {:cont, acc}

        {:error, reason} ->
          {:halt,
           {:error, 503, "ingest failed at event #{obe.sequence_number}: #{inspect(reason)}"}}
      end
    end)
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{errors: %{detail: message}})
  end
end
