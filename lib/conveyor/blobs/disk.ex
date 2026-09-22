defmodule Conveyor.Blobs.Disk do
  @moduledoc """
  Blob adapter storing each blob at `<dir>/<project_prefix>/<d0d1>/<d2d3>/<digest>`
  (`<dir>/<d0d1>/<d2d3>/<digest>` when no `:project_prefix` is given: the layout used
  before blobs were per project).

  Writes go to a temporary file in the same directory and are renamed into place, so a
  crash mid-write never leaves a partial blob under its final name.
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

  @doc "Absolute path of a blob under the configured directory."
  def path(digest, opts) do
    <<a::binary-size(2), b::binary-size(2), _::binary>> = digest

    case Keyword.get(opts, :project_prefix) do
      nil -> Path.join([Keyword.fetch!(opts, :dir), a, b, digest])
      prefix -> Path.join([Keyword.fetch!(opts, :dir), prefix, a, b, digest])
    end
  end
end
