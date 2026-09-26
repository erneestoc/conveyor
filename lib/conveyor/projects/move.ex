defmodule Conveyor.Projects.Move do
  @moduledoc """
  Moves finished builds from one project to another: splitting a project that grew too
  broad (everything landed in `default`) into one per team or repository.

  A build is more than its row: blobs are stored per project under the project's key
  prefix, so every blob a moved build references (its profile, its artifacts, its archived
  raw events and log) is copied into the target project first; the source rows are left
  to the nightly orphan prune once nothing references them. Dashboard rollups of every
  hour the moved builds touch are recomputed for both projects, and both projects' tag
  facets are rebuilt. Builds still streaming are never moved (their worker writes under
  the project it started with). API keys stay with their project: new builds keep landing
  where their key points.

  Run on a node: `bin/conveyor rpc 'Conveyor.Release.move_builds("default", "grpc", "repo:grpc")'`.
  """
  import Ecto.Query

  alias Conveyor.{Audit, Blobs, Invocations, Repo}
  alias Conveyor.Invocations.{Artifact, Invocation}
  alias Conveyor.Metrics.Rollup
  alias Conveyor.Projects.Project

  @chunk 200

  @doc """
  Moves the builds of `from` that match `query` (the search language, e.g. `repo:grpc`;
  `""` for all of them) to `to`. Returns `{:ok, %{builds: n, blobs: n}}`.
  """
  @spec builds(Project.t(), Project.t(), String.t(), keyword()) ::
          {:ok, %{builds: non_neg_integer(), blobs: non_neg_integer()}} | {:error, term()}
  def builds(from, to, query, opts \\ [])

  def builds(%Project{id: id}, %Project{id: id}, _query, _opts), do: {:error, :same_project}

  def builds(%Project{} = from, %Project{} = to, query, opts) when is_binary(query) do
    with {:ok, ast} <- parse(query) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      ids = selected(from, ast, now)

      {moved, blobs, hours} =
        ids
        |> Enum.chunk_every(@chunk)
        |> Enum.reduce({0, 0, MapSet.new()}, fn chunk, {moved, blobs, hours} ->
          {n, copied, chunk_hours} = move_chunk(from, to, chunk)
          {moved + n, blobs + copied, MapSet.union(hours, chunk_hours)}
        end)

      if moved > 0 do
        for hour <- hours, project <- [from, to], do: Rollup.roll!(project.id, hour)
        Invocations.rebuild_tag_keys!(from.id)
        Invocations.rebuild_tag_keys!(to.id)
      end

      Audit.log(Keyword.get(opts, :actor, "release"), "project.move_builds",
        project_id: to.id,
        subject: {"project", to.id},
        metadata: %{from: from.slug, to: to.slug, query: query, builds: moved, blobs: blobs}
      )

      {:ok, %{builds: moved, blobs: blobs}}
    end
  end

  defp parse(""), do: {:ok, []}

  # `Query.parse!/1` answers `[]` (every build) for invalid input; a move must not.
  defp parse(query) do
    case Conveyor.Query.parse(query) do
      {:ok, []} -> {:error, {:bad_query, "matches every build; pass \"\" to move all"}}
      {:ok, ast} -> {:ok, ast}
      {:error, reason} -> {:error, {:bad_query, reason}}
    end
  end

  defp selected(%Project{id: project_id}, ast, now) do
    Invocation
    |> where([i], i.project_id == ^project_id and i.status != "in_progress")
    |> then(fn q ->
      if ast == [], do: q, else: where(q, ^Conveyor.Query.to_dynamic(ast, now: now))
    end)
    |> order_by([i], i.inserted_at)
    |> select([i], i.id)
    |> Repo.all()
  end

  defp move_chunk(from, to, ids) do
    copied = ids |> referenced_digests() |> Enum.count(&copy_blob(from, to, &1))

    {n, rows} =
      Repo.update_all(
        from(i in Invocation,
          where: i.id in ^ids and i.project_id == ^from.id and i.status != "in_progress",
          select: fragment("date_trunc('hour', ?)", i.started_at)
        ),
        set: [project_id: to.id]
      )

    hours = rows |> Enum.reject(&is_nil/1) |> Enum.map(&to_hour/1) |> MapSet.new()
    {n, copied, hours}
  end

  defp to_hour(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_hour(%DateTime{} = at), do: at

  defp referenced_digests(ids) do
    own =
      Repo.all(
        from i in Invocation,
          where: i.id in ^ids,
          select: [i.profile_blob, i.raw_blob, i.log_blob]
      )

    artifacts = Repo.all(from a in Artifact, where: a.invocation_id in ^ids, select: a.digest)

    (List.flatten(own) ++ artifacts) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # Copies one blob into the target project's prefix (true when bytes were copied). A blob
  # the target already holds, or the source no longer has, is left as it is.
  defp copy_blob(from, to, digest) do
    source = Blobs.get(from, digest)

    cond do
      source == nil ->
        false

      Blobs.exists?(to, digest) ->
        false

      true ->
        with {:ok, chunks} <- Blobs.stream(from, digest, chunk_size: 256 * 1024),
             {:ok, _} <-
               Blobs.put(to, chunks,
                 digest: digest,
                 content_type: source.content_type,
                 source: source.source
               ) do
          true
        else
          # Never move a build whose bytes did not reach the target: stop here (the chunks
          # moved so far are complete) and let the caller retry.
          {:error, reason} -> raise "move: blob #{digest} not copied: #{inspect(reason)}"
        end
    end
  end
end
