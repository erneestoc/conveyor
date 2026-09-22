defmodule Conveyor.Blobs do
  @moduledoc """
  Content-addressed blob store: profiles, test logs and CAS uploads, keyed by project and
  the lowercase hex SHA-256 of their content.

  Bytes live in the configured adapter (`Conveyor.Blobs.Disk` or `Conveyor.Blobs.S3`)
  under the project's key prefix (`Conveyor.Projects.blob_prefix/1`, the slug by default),
  so one project's data is one prefix in the bucket or on disk: it can be listed, given a
  lifecycle rule or deleted on its own. The `blobs` table records size, type, origin, the
  prefix used and an optional expiry per `(project_id, digest)`. Every write hashes the
  content while streaming it and refuses to store it under a digest it does not match.
  Projects never share rows: the same content uploaded by two projects is stored twice.
  """
  import Ecto.Query

  alias Conveyor.Blobs.Blob
  alias Conveyor.Projects
  alias Conveyor.Repo

  @digest_re ~r/^[0-9a-f]{64}$/

  @type digest :: String.t()
  @type project :: integer() | Projects.Project.t()

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
  Stores content for a project under its digest. `content` is a binary, iodata or a
  stream of binaries. When `:digest` is given the content must hash to it. Options:
  `:content_type`, `:source` (`"fetch" | "upload" | "cas" | "derived"`), `:ttl_seconds`.
  """
  @spec put(project(), iodata() | Enumerable.t(), keyword()) ::
          {:ok, Blob.t()} | {:error, :digest_mismatch | :invalid_digest | term()}
  def put(project, content, opts \\ []) do
    expected = Keyword.get(opts, :digest)
    project_id = project_id(project)
    prefix = Projects.blob_prefix(project)

    cond do
      expected != nil and not valid_digest?(expected) ->
        {:error, :invalid_digest}

      is_binary(content) or is_list(content) ->
        actual = digest(content)

        if expected in [nil, actual],
          do:
            store(
              project_id,
              prefix,
              actual,
              [IO.iodata_to_binary(content)],
              IO.iodata_length(content),
              opts
            ),
          else: {:error, :digest_mismatch}

      expected != nil ->
        # Streaming content must be written before its digest is known; write under the
        # expected digest, then verify and roll back on mismatch.
        {adapter, aopts} = adapter(prefix)
        {hashed, counter} = hashing(content)

        with :ok <- adapter.put(expected, hashed, aopts) do
          {actual, size} = Agent.get(counter, & &1)
          Agent.stop(counter)

          if actual == expected do
            record(project_id, prefix, expected, size, adapter, opts)
          else
            adapter.delete(expected, aopts)
            {:error, :digest_mismatch}
          end
        end

      true ->
        # Unknown digest for a stream: spool it to a local file while hashing, then store
        # it under the digest. Memory stays bounded whatever the upload size.
        spool(project_id, prefix, content, opts)
    end
  end

  defp spool(project_id, prefix, content, opts) do
    tmp = Path.join(System.tmp_dir!(), "conveyor-spool-#{System.unique_integer([:positive])}")
    {hashed, counter} = hashing(content)

    try do
      hashed |> Stream.into(File.stream!(tmp, 64 * 1024)) |> Stream.run()
      {digest, size} = Agent.get(counter, & &1)
      store(project_id, prefix, digest, File.stream!(tmp, 64 * 1024), size, opts)
    rescue
      e -> {:error, e}
    after
      Agent.stop(counter)
      File.rm(tmp)
    end
  end

  defp store(project_id, prefix, digest, chunks, size, opts) do
    {adapter, aopts} = adapter(prefix)

    with :ok <- adapter.put(digest, chunks, aopts) do
      record(project_id, prefix, digest, size, adapter, opts)
    end
  end

  # Adapter options for one project's prefix (nil = the pre-prefix flat layout).
  defp adapter(prefix) do
    {adapter, aopts} = adapter()
    {adapter, Keyword.put(aopts, :project_prefix, prefix)}
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

  defp record(project_id, prefix, digest, size, adapter, opts) do
    now = DateTime.utc_now()

    expires_at =
      case Keyword.get(opts, :ttl_seconds) do
        nil -> nil
        ttl -> DateTime.add(now, ttl, :second)
      end

    row = %{
      project_id: project_id,
      digest: digest,
      prefix: prefix,
      size: size,
      content_type: Keyword.get(opts, :content_type),
      storage: storage_name(adapter),
      source: Keyword.get(opts, :source, "fetch"),
      expires_at: expires_at,
      last_used_at: now,
      inserted_at: now
    }

    # A re-upload refreshes the expiry and records where the bytes now live; a pinned
    # blob (nil expiry) stays pinned.
    {1, [blob]} =
      Repo.insert_all(Blob, [row],
        on_conflict: [
          set: [
            last_used_at: now,
            prefix: prefix,
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
        conflict_target: [:project_id, :digest],
        returning: true
      )

    {:ok, blob}
  end

  defp storage_name(Conveyor.Blobs.Disk), do: "disk"
  defp storage_name(Conveyor.Blobs.S3), do: "s3"
  defp storage_name(mod), do: inspect(mod)

  @spec get(project(), digest()) :: Blob.t() | nil
  def get(project, digest) do
    if valid_digest?(digest),
      do: Repo.get_by(Blob, project_id: project_id(project), digest: digest),
      else: nil
  end

  @doc "True when the blob row exists and its bytes are present in the adapter."
  @spec exists?(project(), digest()) :: boolean()
  def exists?(project, digest) do
    case get(project, digest) do
      nil ->
        false

      blob ->
        {adapter, aopts} = adapter(blob.prefix)
        adapter.exists?(digest, aopts)
    end
  end

  @doc "Which of the digests the project does not hold (used by the CAS sink)."
  @spec missing(project(), [digest()]) :: [digest()]
  def missing(project, digests) do
    valid = Enum.filter(digests, &valid_digest?/1)
    project_id = project_id(project)

    present =
      Repo.all(
        from b in Blob,
          where: b.project_id == ^project_id and b.digest in ^valid,
          select: b.digest
      )
      |> MapSet.new()

    Enum.reject(digests, &(&1 in present))
  end

  @spec stream(project(), digest(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, :not_found | term()}
  def stream(project, digest, opts \\ []) do
    case get(project, digest) do
      nil ->
        {:error, :not_found}

      blob ->
        {adapter, aopts} = adapter(blob.prefix)

        case adapter.stream(digest, Keyword.merge(aopts, opts)) do
          {:ok, stream} ->
            touch(blob)
            {:ok, stream}

          other ->
            other
        end
    end
  end

  @spec read(project(), digest()) :: {:ok, binary()} | {:error, :not_found | term()}
  def read(project, digest) do
    with {:ok, stream} <- stream(project, digest) do
      {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
    end
  end

  @spec delete(project(), digest()) :: :ok | {:error, term()}
  def delete(project, digest) do
    case get(project, digest) do
      nil -> :ok
      blob -> delete_blob(blob)
    end
  end

  defp delete_blob(%Blob{} = blob) do
    {adapter, aopts} = adapter(blob.prefix)

    with :ok <- adapter.delete(blob.digest, aopts) do
      Repo.delete_all(
        from b in Blob, where: b.project_id == ^blob.project_id and b.digest == ^blob.digest
      )

      :ok
    end
  end

  @doc "Removes the expiry so retention never drops a blob an invocation references."
  @spec pin(project(), digest()) :: :ok
  def pin(project, digest) do
    project_id = project_id(project)

    Repo.update_all(
      from(b in Blob, where: b.project_id == ^project_id and b.digest == ^digest),
      set: [expires_at: nil]
    )

    :ok
  end

  defp touch(%Blob{project_id: project_id, digest: digest}) do
    Repo.update_all(
      from(b in Blob, where: b.project_id == ^project_id and b.digest == ^digest),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Deletes blobs whose expiry has passed. Returns the number removed."
  @spec prune_expired(DateTime.t()) :: non_neg_integer()
  def prune_expired(now \\ DateTime.utc_now()) do
    from(b in Blob, where: not is_nil(b.expires_at) and b.expires_at < ^now)
    |> Repo.all()
    |> Enum.count(fn blob -> delete_blob(blob) == :ok end)
  end

  @doc """
  Deletes pinned blobs nothing references any more: no artifact of an invocation in the
  same project and no invocation's profile. Build retention deletes invocations (and their
  artifact rows cascade); this is what frees their bytes. Blobs younger than `grace`
  seconds are kept, so a blob stored moments before its artifact row is never touched.
  """
  @spec prune_orphans(DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def prune_orphans(now \\ DateTime.utc_now(), grace \\ 3600) do
    cutoff = DateTime.add(now, -grace, :second)

    referenced_by_artifact =
      from a in "invocation_artifacts",
        join: i in "invocations",
        on: i.id == a.invocation_id,
        where:
          a.digest == parent_as(:blob).digest and i.project_id == parent_as(:blob).project_id,
        select: 1

    referenced_as_profile =
      from i in "invocations",
        where:
          i.profile_blob == parent_as(:blob).digest and
            i.project_id == parent_as(:blob).project_id,
        select: 1

    from(b in Blob, as: :blob)
    |> where([b], is_nil(b.expires_at) and b.inserted_at < ^cutoff)
    |> where([b], not exists(subquery(referenced_by_artifact)))
    |> where([b], not exists(subquery(referenced_as_profile)))
    |> Repo.all()
    |> Enum.count(fn blob -> delete_blob(blob) == :ok end)
  end

  defp project_id(%Projects.Project{id: id}), do: id
  defp project_id(id) when is_integer(id), do: id
end
