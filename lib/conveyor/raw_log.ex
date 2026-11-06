defmodule Conveyor.RawLog do
  @moduledoc """
  The raw log (PLAN §25 step 2): in blob mode a writer shard puts each group commit's
  compressed payloads into one object here, and the segment rows in Postgres carry a byte
  range of it instead of the bytes. Objects are server-internal (never served by URL,
  read by range through the server), span projects, and are time-ordered by key under
  `rawlog/<node>/<shard>/<ulid>` in the same backend as the blob store (`BLOB_STORE`).

  Each object is registered in `raw_log_objects` *before* it is written, in its own tiny
  transaction, so `sweep/1` can delete objects older than the raw retention, orphans of a
  failed commit included, without listing the store.
  """

  import Ecto.Query
  alias Conveyor.Repo

  @prefix "rawlog"

  @doc "Whether the writer puts raw bytes into objects (`RAW_LOG=blob`) or into rows."
  @spec blob_mode?() :: boolean()
  def blob_mode?, do: Application.get_env(:conveyor, __MODULE__, [])[:mode] == :blob

  @doc "The writer's hold in blob mode: one object per shard per interval."
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: Application.get_env(:conveyor, __MODULE__, [])[:flush_ms] || 1000

  @doc "A fresh, time-ordered object key for a shard of this node."
  @spec new_key(term()) :: String.t()
  def new_key(shard) do
    ms = System.os_time(:millisecond)
    rand = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
    node = node() |> Atom.to_string() |> String.replace(~r/[^a-z0-9]+/i, "-")

    "#{@prefix}/#{node}/#{shard}/#{ms |> Integer.to_string(32) |> String.downcase() |> String.pad_leading(10, "0")}#{rand}"
  end

  @doc """
  Registers and writes an object. The row goes first in its own transaction; the bytes
  are durable when this returns `:ok`.
  """
  @spec put(String.t(), iodata()) :: :ok | {:error, term()}
  def put(key, iodata) do
    Repo.insert_all("raw_log_objects", [%{key: key}], on_conflict: :nothing)

    case adapter() do
      {:disk, dir} ->
        path = Path.join(dir, key)
        File.mkdir_p!(Path.dirname(path))
        File.write(path, iodata)

      {:s3, opts} ->
        Conveyor.Blobs.S3.put_object(
          key,
          IO.iodata_to_binary(iodata),
          Keyword.put(opts, :project_prefix, nil)
        )
    end
  end

  @doc "Reads `length` bytes at `offset` of an object."
  @spec get_range(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def get_range(key, offset, length) do
    case adapter() do
      {:disk, dir} ->
        with {:ok, io} <- File.open(Path.join(dir, key), [:read, :binary, :raw]) do
          try do
            case :file.pread(io, offset, length) do
              {:ok, data} when byte_size(data) == length -> {:ok, data}
              {:ok, _} -> {:error, :short_read}
              :eof -> {:error, :short_read}
              other -> other
            end
          after
            File.close(io)
          end
        end

      {:s3, opts} ->
        Conveyor.Blobs.S3.get_range(key, offset, length, Keyword.put(opts, :project_prefix, nil))
    end
  end

  @doc "Deletes the objects registered before `cutoff` and their rows; returns the count."
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(%DateTime{} = cutoff) do
    keys =
      Repo.all(
        from(o in "raw_log_objects", where: o.inserted_at < ^cutoff, select: o.key, limit: 10_000)
      )

    Enum.reduce(keys, 0, fn key, n ->
      case delete(key) do
        :ok ->
          Repo.delete_all(from(o in "raw_log_objects", where: o.key == ^key))
          n + 1

        {:error, reason} ->
          :telemetry.execute([:conveyor, :raw_log, :sweep_failed], %{count: 1}, %{
            key: key,
            reason: reason
          })

          n
      end
    end)
  end

  defp delete(key) do
    case adapter() do
      {:disk, dir} ->
        case File.rm(Path.join(dir, key)) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          other -> other
        end

      {:s3, opts} ->
        Conveyor.Blobs.S3.delete(key, Keyword.put(opts, :project_prefix, nil))
    end
  end

  defp adapter do
    case Conveyor.Blobs.adapter() do
      {Conveyor.Blobs.Disk, opts} -> {:disk, opts[:dir]}
      {Conveyor.Blobs.S3, opts} -> {:s3, opts}
    end
  end
end
