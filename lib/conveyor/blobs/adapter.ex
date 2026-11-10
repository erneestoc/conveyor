defmodule Conveyor.Blobs.Adapter do
  @moduledoc """
  The object store: the seam between Conveyor and where bytes live (a directory, an
  S3-compatible bucket, a test double). One adapter is configured per deployment
  (`Conveyor.Blobs.adapter/0`) and serves two kinds of object in the same backend.

  **Content-addressed blobs** (`put/3`, `stream/2`, `exists?/2`, `delete/2`): the key is a
  lowercase hex SHA-256 digest, validated by `Conveyor.Blobs` before any call reaches an
  adapter, stored under the project's prefix (`:project_prefix` in the options).

  **Keyed objects** (`put_object/3`, `get_range/4`, `delete_objects/2`): the key is a
  relative path the server made up (`rawlog/<node>/<shard>/<id>`, `Conveyor.RawLog`),
  outside every project prefix. They are written whole, once, and must be durable when
  `put_object/3` returns, because an acknowledgement follows; they are read by byte range
  and deleted in bulk.

  Both kinds live in one behaviour because they are one store: the same bucket or
  directory, the same credentials, the same outage. A second behaviour would have every
  backend implement two modules that are configured and fail together, and a test double
  that injects a store failure would have to be installed twice.
  """

  @type digest :: String.t()
  @type key :: String.t()

  @doc "Stores the bytes produced by the enumerable (binaries) under the digest."
  @callback put(digest, Enumerable.t(), keyword()) :: :ok | {:error, term()}

  @doc "Returns a stream of binaries for the blob."
  @callback stream(digest, keyword()) :: {:ok, Enumerable.t()} | {:error, :not_found | term()}

  @callback exists?(digest, keyword()) :: boolean()

  @callback delete(digest, keyword()) :: :ok | {:error, term()}

  @doc """
  Writes an object under a key, whole or not at all, durable when it returns `:ok`.
  Putting the same bytes under the same key again is allowed and changes nothing.
  """
  @callback put_object(key, iodata(), keyword()) :: :ok | {:error, term()}

  @doc """
  Reads exactly `length` bytes at `offset`. `{:error, :not_found}` when there is no such
  object, `{:error, :short_read}` when it ends before the range does: never fewer bytes
  than asked for.
  """
  @callback get_range(key, offset :: non_neg_integer(), length :: pos_integer(), keyword()) ::
              {:ok, binary()} | {:error, :not_found | :short_read | term()}

  @doc """
  Deletes objects, as many per request as the backend takes. Returns the keys that are
  gone (deleted now, or absent already) and the ones that are not, each with its reason.
  Deleting one object is a list of one.
  """
  @callback delete_objects([key], keyword()) ::
              {deleted :: [key], failed :: [{key, term()}]}

  @doc """
  Counts a failed adapter call (`conveyor_blobs_errors_count{op}`), so a bad bucket
  policy or a full disk is an alert whichever kind of object hit it. A missing object is
  an answer, not a failure. Returns the result.
  """
  @spec counted(atom(), result) :: result when result: term()
  def counted(op, {:error, reason} = result) when reason != :not_found do
    :telemetry.execute([:conveyor, :blobs, :errors], %{count: 1}, %{op: op})
    result
  end

  def counted(_op, result), do: result
end
