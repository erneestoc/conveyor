defmodule Conveyor.Blobs.Adapter do
  @moduledoc """
  Storage backend for content-addressed blobs.

  Keys are lowercase hex SHA-256 digests, validated by `Conveyor.Blobs` before any call
  reaches an adapter, so adapters never see path separators or other user input.
  """

  @type digest :: String.t()

  @doc "Stores the bytes produced by the enumerable (binaries) under the digest."
  @callback put(digest, Enumerable.t(), keyword()) :: :ok | {:error, term()}

  @doc "Returns a stream of binaries for the blob."
  @callback stream(digest, keyword()) :: {:ok, Enumerable.t()} | {:error, :not_found | term()}

  @callback exists?(digest, keyword()) :: boolean()

  @callback delete(digest, keyword()) :: :ok | {:error, term()}
end
