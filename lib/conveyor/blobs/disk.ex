defmodule Conveyor.Blobs.Disk do
  @moduledoc """
  Blob adapter storing each blob at `<dir>/<project_prefix>/<d0d1>/<d2d3>/<digest>`
  (`<dir>/<d0d1>/<d2d3>/<digest>` when no `:project_prefix` is given: the layout used
  before blobs were per project).

  Writes go to a temporary file in the same directory and are renamed into place, so a
  crash mid-write never leaves a partial blob under its final name.

  Keyed objects (the raw log) are files at `<dir>/<key>`, written durably
  (`put_object/3`).
  """
  @behaviour Conveyor.Blobs.Adapter

  @impl true
  def put(digest, enum, opts) do
    path = path(digest, opts)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      enum |> Stream.into(File.stream!(tmp, 64 * 1024)) |> Stream.run()
      File.rename!(tmp, path)
      :ok
    rescue
      e -> {:error, e}
    after
      File.rm(tmp)
    end
  end

  @impl true
  def stream(digest, opts) do
    path = path(digest, opts)

    if File.regular?(path),
      do: {:ok, File.stream!(path, Keyword.get(opts, :chunk_size, 64 * 1024))},
      else: {:error, :not_found}
  end

  @impl true
  def exists?(digest, opts), do: File.regular?(path(digest, opts))

  @impl true
  def delete(digest, opts) do
    case File.rm(path(digest, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- keyed objects ----------------------------------------------------------------------

  @doc """
  Writes `<dir>/<key>`. An acknowledgement follows this write, so `:ok` means the object
  survives a crash of the machine: the bytes go to a temporary name and are synced, the
  rename makes the object appear whole or not at all, and the directory is synced so the
  name is on disk too (as are the directories this call had to create). `fsync: false`
  skips the syncs and keeps the rename.
  """
  @impl true
  def put_object(key, iodata, opts) do
    root = Keyword.fetch!(opts, :dir)
    path = object_path(key, opts)
    dir = Path.dirname(path)
    sync? = Keyword.get(opts, :fsync, true)
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    result =
      with :ok <- ensure_dir(root, dir, sync?),
           {:ok, io} <- :file.open(tmp, [:write, :raw, :binary]),
           :ok <- write_and_close(io, iodata, sync?),
           :ok <- :file.rename(tmp, path) do
        if sync?, do: sync_dir(dir), else: :ok
      end

    if result != :ok, do: File.rm(tmp)
    result
  end

  defp write_and_close(io, iodata, sync?) do
    with :ok <- :file.write(io, iodata),
         :ok <- if(sync?, do: :file.sync(io), else: :ok) do
      :file.close(io)
    else
      error ->
        :file.close(io)
        error
    end
  end

  defp ensure_dir(root, dir, sync?) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir) do
        if sync?, do: sync_up(Path.dirname(dir), root), else: :ok
      end
    end
  end

  # New directories are entries of their parents: sync those up to the store's root.
  defp sync_up(dir, root) do
    with :ok <- sync_dir(dir) do
      if dir == root or not String.starts_with?(dir, root),
        do: :ok,
        else: sync_up(Path.dirname(dir), root)
    end
  end

  defp sync_dir(dir) do
    with {:ok, io} <- :file.open(dir, [:read, :raw, :directory]) do
      result = :file.sync(io)
      :file.close(io)
      result
    end
  end

  @impl true
  def get_range(key, offset, length, opts) do
    case :file.open(object_path(key, opts), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          case :file.pread(io, offset, length) do
            {:ok, data} when byte_size(data) == length -> {:ok, data}
            {:ok, _} -> {:error, :short_read}
            :eof -> {:error, :short_read}
            {:error, reason} -> {:error, reason}
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_objects(keys, opts) do
    {deleted, failed} =
      Enum.reduce(keys, {[], []}, fn key, {deleted, failed} ->
        case File.rm(object_path(key, opts)) do
          :ok -> {[key | deleted], failed}
          {:error, :enoent} -> {[key | deleted], failed}
          {:error, reason} -> {deleted, [{key, reason} | failed]}
        end
      end)

    {Enum.reverse(deleted), Enum.reverse(failed)}
  end

  @doc "Absolute path of a keyed object. The key is a relative path without `.` or `..` segments."
  def object_path(key, opts) do
    if safe_key?(key),
      do: Path.join(Keyword.fetch!(opts, :dir), key),
      else: raise(ArgumentError, "object key #{inspect(key)} leaves the store")
  end

  # Checked on the string alone: `Path.safe_relative/2` asks the file server for the
  # working directory and looks for symlinks on every call, which showed as 5 % more work
  # per raw-log put (PLAN §26.5, bench).
  defp safe_key?(key),
    do: key |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))

  @doc "Absolute path of a blob under the configured directory."
  def path(digest, opts) do
    <<a::binary-size(2), b::binary-size(2), _::binary>> = digest

    case Keyword.get(opts, :project_prefix) do
      nil -> Path.join([Keyword.fetch!(opts, :dir), a, b, digest])
      prefix -> Path.join([Keyword.fetch!(opts, :dir), prefix, a, b, digest])
    end
  end
end
