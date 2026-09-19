defmodule Conveyor.Blobs do
  @moduledoc """
  Content-addressed blob store: profiles, test logs and CAS uploads, keyed by the
  lowercase hex SHA-256 of their content.

  Bytes live in the configured adapter (`Conveyor.Blobs.Disk` or `Conveyor.Blobs.S3`);
  the `blobs` table records size, type, origin and an optional expiry. Every write hashes
  the content while streaming it and refuses to store it under a digest it does not match.
  """
  import Ecto.Query

  alias Conveyor.Blobs.Blob
  alias Conveyor.Repo

  @digest_re ~r/^[0-9a-f]{64}$/

  @type digest :: String.t()

  @doc "True for a lowercase hex SHA-256 digest (the only accepted key shape)."
  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(d) when is_binary(d), do: Regex.match?(@digest_re, d)
  def valid_digest?(_), do: false

  @doc "Hex SHA-256 of a binary or iodata."
  @spec digest(iodata()) :: digest()
  def digest(iodata), do: :crypto.hash(:sha256, iodata) |> Base.encode16(case: :lower)

  @doc "The configured adapter module and its options."
  @spec adapter() :: {module(), keyword()}
  def adapter do
    conf = Application.get_env(:conveyor, __MODULE__, [])

    case Keyword.get(conf, :adapter, :disk) do
      :disk -> {Conveyor.Blobs.Disk, [dir: Keyword.get(conf, :dir, "tmp/blobs")]}
      :s3 -> {Conveyor.Blobs.S3, Keyword.get(conf, :s3, [])}
      module when is_atom(module) -> {module, Keyword.get(conf, :opts, [])}
    end
  end

  @doc """
  Stores content under its digest. `content` is a binary, iodata or a stream of binaries.
  When `:digest` is given the content must hash to it. Options: `:content_type`,
  `:source` (`"fetch" | "upload" | "cas" | "derived"`), `:ttl_seconds`.
  """
  @spec put(iodata() | Enumerable.t(), keyword()) ::
          {:ok, Blob.t()} | {:error, :digest_mismatch | :invalid_digest | term()}
  def put(content, opts \\ []) do
    expected = Keyword.get(opts, :digest)

    cond do
      expected != nil and not valid_digest?(expected) ->
        {:error, :invalid_digest}

      is_binary(content) or is_list(content) ->
        actual = digest(content)

        if expected in [nil, actual],
          do: store(actual, [IO.iodata_to_binary(content)], IO.iodata_length(content), opts),
          else: {:error, :digest_mismatch}

      expected != nil ->
        # Streaming content must be written before its digest is known; write under the
        # expected digest, then verify and roll back on mismatch.
        {adapter, aopts} = adapter()
        {hashed, counter} = hashing(content)

        with :ok <- adapter.put(expected, hashed, aopts) do
          {actual, size} = Agent.get(counter, & &1)
          Agent.stop(counter)

          if actual == expected do
            record(expected, size, adapter, opts)
          else
            adapter.delete(expected, aopts)
            {:error, :digest_mismatch}
          end
        end

      true ->
        # Unknown digest for a stream: buffer it (callers with large streams pass :digest).
        put(content |> Enum.to_list() |> IO.iodata_to_binary(), opts)
    end
  end

  defp store(digest, chunks, size, opts) do
    {adapter, aopts} = adapter()

    with :ok <- adapter.put(digest, chunks, aopts) do
      record(digest, size, adapter, opts)
    end
  end

  defp hashing(enum) do
    {:ok, counter} = Agent.start_link(fn -> {nil, 0} end)

    stream =
      Stream.transform(
        enum,
        fn -> {:crypto.hash_init(:sha256), 0} end,
        fn chunk, {hash, size} ->
          {[chunk], {:crypto.hash_update(hash, chunk), size + byte_size(chunk)}}
        end,
        fn {hash, size} ->
          Agent.update(counter, fn _ ->
            {Base.encode16(:crypto.hash_final(hash), case: :lower), size}
          end)
        end
      )

    {stream, counter}
  end

  defp record(digest, size, adapter, opts) do
    now = DateTime.utc_now()

    expires_at =
      case Keyword.get(opts, :ttl_seconds) do
        nil -> nil
        ttl -> DateTime.add(now, ttl, :second)
      end

    row = %{
      digest: digest,
      size: size,
      content_type: Keyword.get(opts, :content_type),
      storage: storage_name(adapter),
      source: Keyword.get(opts, :source, "fetch"),
      expires_at: expires_at,
      last_used_at: now,
      inserted_at: now
    }

    # A re-upload refreshes the expiry; a pinned blob (nil expiry) stays pinned.
    {1, [blob]} =
      Repo.insert_all(Blob, [row],
        on_conflict: [
          set: [
            last_used_at: now,
            expires_at:
              dynamic(
                [b],
                fragment(
                  "CASE WHEN ? IS NULL THEN NULL ELSE ?::timestamp END",
                  b.expires_at,
                  ^expires_at
                )
              )
          ]
        ],
        conflict_target: :digest,
        returning: true
      )

    {:ok, blob}
  end

  defp storage_name(Conveyor.Blobs.Disk), do: "disk"
  defp storage_name(Conveyor.Blobs.S3), do: "s3"
  defp storage_name(mod), do: inspect(mod)

  @spec get(digest()) :: Blob.t() | nil
  def get(digest) do
    if valid_digest?(digest), do: Repo.get(Blob, digest), else: nil
  end

  @doc "True when the blob row exists and its bytes are present in the adapter."
  @spec exists?(digest()) :: boolean()
  def exists?(digest) do
    {adapter, aopts} = adapter()
    valid_digest?(digest) and get(digest) != nil and adapter.exists?(digest, aopts)
  end

  @doc "Which of the digests are missing from the store (used by the CAS sink)."
  @spec missing([digest()]) :: [digest()]
  def missing(digests) do
    valid = Enum.filter(digests, &valid_digest?/1)

    present =
      Repo.all(from b in Blob, where: b.digest in ^valid, select: b.digest) |> MapSet.new()

    Enum.reject(digests, &(&1 in present))
  end

  @spec stream(digest(), keyword()) :: {:ok, Enumerable.t()} | {:error, :not_found | term()}
  def stream(digest, opts \\ []) do
    {adapter, aopts} = adapter()

    if valid_digest?(digest) do
      case adapter.stream(digest, Keyword.merge(aopts, opts)) do
        {:ok, stream} ->
          touch(digest)
          {:ok, stream}

        other ->
          other
      end
    else
      {:error, :not_found}
    end
  end

  @spec read(digest()) :: {:ok, binary()} | {:error, :not_found | term()}
  def read(digest) do
    with {:ok, stream} <- stream(digest) do
      {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
    end
  end

  @spec delete(digest()) :: :ok | {:error, term()}
  def delete(digest) do
    {adapter, aopts} = adapter()

    if valid_digest?(digest) do
      with :ok <- adapter.delete(digest, aopts) do
        Repo.delete_all(from b in Blob, where: b.digest == ^digest)
        :ok
      end
    else
      :ok
    end
  end

  @doc "Removes the expiry so retention never drops a blob an invocation references."
  @spec pin(digest()) :: :ok
  def pin(digest) do
    Repo.update_all(from(b in Blob, where: b.digest == ^digest), set: [expires_at: nil])
    :ok
  end

  defp touch(digest) do
    Repo.update_all(from(b in Blob, where: b.digest == ^digest),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Deletes blobs whose expiry has passed. Returns the number removed."
  @spec prune_expired(DateTime.t()) :: non_neg_integer()
  def prune_expired(now \\ DateTime.utc_now()) do
    from(b in Blob, where: not is_nil(b.expires_at) and b.expires_at < ^now, select: b.digest)
    |> Repo.all()
    |> Enum.count(fn digest -> delete(digest) == :ok end)
  end
end
