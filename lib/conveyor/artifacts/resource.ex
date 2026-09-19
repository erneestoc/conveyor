defmodule Conveyor.Artifacts.Resource do
  @moduledoc """
  Parses Remote Execution API blob resource names and `bytestream://` URIs.

  Reads: `[instance/]blobs/[sha256/]<hash>/<size>`.
  Writes: `[instance/]uploads/<uuid>/blobs/[sha256/]<hash>/<size>[/metadata]`.
  Only SHA-256 is accepted (64 lowercase hex characters).
  """

  @type t :: %__MODULE__{
          host: String.t() | nil,
          port: pos_integer() | nil,
          instance: String.t(),
          resource: String.t(),
          hash: String.t(),
          size: non_neg_integer()
        }

  defstruct host: nil, port: nil, instance: "", resource: "", hash: nil, size: 0

  @read ~r|^(?:(?<instance>.+?)/)?blobs/(?:(?<fun>[a-z0-9]+)/)?(?<hash>[0-9a-f]{64})/(?<size>\d+)$|
  @write ~r|^(?:(?<instance>.+?)/)?uploads/[^/]+/blobs/(?:(?<fun>[a-z0-9]+)/)?(?<hash>[0-9a-f]{64})/(?<size>\d+)(?:/.*)?$|

  @doc "Parses a read resource name."
  @spec parse_read(String.t()) :: {:ok, t()} | {:error, :invalid_resource | :unsupported_digest}
  def parse_read(name) when is_binary(name), do: parse(:read, @read, name)

  @doc "Parses a write (upload) resource name."
  @spec parse_write(String.t()) :: {:ok, t()} | {:error, :invalid_resource | :unsupported_digest}
  def parse_write(name) when is_binary(name), do: parse(:write, @write, name)

  defp parse(kind, re, name) do
    case Regex.named_captures(re, name) do
      %{"fun" => fun} when fun not in ["", "sha256"] ->
        {:error, :unsupported_digest}

      %{"instance" => instance, "hash" => hash, "size" => size} ->
        if kind == :read and upload_prefix?(instance),
          do: {:error, :invalid_resource},
          else:
            {:ok,
             %__MODULE__{
               instance: instance,
               resource: name,
               hash: hash,
               size: String.to_integer(size)
             }}

      nil ->
        {:error, :invalid_resource}
    end
  end

  # A read resource whose "instance" ends in uploads/<id> is really a malformed write.
  defp upload_prefix?(instance), do: Regex.match?(~r{(^|/)uploads/[^/]+$}, instance)

  @doc """
  Parses a `bytestream://host[:port]/<read resource>` URI as written by Bazel into BEP
  `File.uri` fields. `file://` URIs are reported as `:local_file`.
  """
  @spec parse_uri(String.t()) ::
          {:ok, t()}
          | {:error, :local_file | :unsupported_scheme | :invalid_resource | :unsupported_digest}
  def parse_uri("bytestream://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [authority, resource] when authority != "" ->
        {host, port} = split_authority(authority)

        with {:ok, ref} <- parse_read(resource) do
          {:ok, %{ref | host: host, port: port}}
        end

      _ ->
        {:error, :invalid_resource}
    end
  end

  def parse_uri("file://" <> _), do: {:error, :local_file}
  def parse_uri(_), do: {:error, :unsupported_scheme}

  defp split_authority(authority) do
    case String.split(authority, ":") do
      [host, port] ->
        case Integer.parse(port) do
          {p, ""} when p in 1..65535 -> {host, p}
          _ -> {authority, nil}
        end

      _ ->
        {authority, nil}
    end
  end

  @doc "`host:port` (or just the host when the URI carried no port)."
  @spec authority(t()) :: String.t()
  def authority(%__MODULE__{host: host, port: nil}), do: host
  def authority(%__MODULE__{host: host, port: port}), do: "#{host}:#{port}"
end
