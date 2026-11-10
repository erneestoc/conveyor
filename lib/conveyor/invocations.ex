defmodule Conveyor.Invocations do
  @moduledoc "Read side of invocations: list, detail, events, log, targets, tests, actions."
  import Ecto.Query

  alias Conveyor.Invocations.{
    Action,
    Invocation,
    LogSegment,
    Metrics,
    TagKey,
    Target,
    TestResult
  }

  alias Conveyor.RawStore
  alias Conveyor.Repo

  @doc """
  An invocation by id, or nil. `project_ids: [ids]` (from `Conveyor.Accounts.Scope.project_ids/1`)
  restricts the lookup to those projects, so a foreign id reads as not found; `:all` (the
  default) is for trusted callers such as workers.
  """
  @spec get(String.t(), keyword()) :: Invocation.t() | nil
  def get(id, opts \\ []) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Invocation
        |> where([i], i.id == ^uuid)
        |> maybe_projects(Keyword.get(opts, :project_ids, :all))
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Arguments for a background job about an invocation: the id and its project, so the
  worker loads the build inside the project it was enqueued for (`for_job/1`).
  """
  @spec job_args(Invocation.t()) :: %{invocation_id: String.t(), project_id: integer()}
  def job_args(%Invocation{id: id, project_id: project_id}),
    do: %{invocation_id: id, project_id: project_id}

  @doc """
  The invocation a job's arguments name, or nil. Scoped by the project the job carries;
  jobs enqueued before the arguments carried one are looked up by id alone.
  """
  @spec for_job(map()) :: Invocation.t() | nil
  def for_job(%{"invocation_id" => id, "project_id" => project_id}) when is_integer(project_id),
    do: get(id, project_ids: [project_id])

  def for_job(%{"invocation_id" => id}), do: get(id)

  @doc """
  Newest-first page of invocations. Options: `:project_id`, `:project_ids` (`:all` or the
  list a scope may read), `:status`, `:statuses` (list), `:limit` (default 50), `:before`
  (`{started_at, id}` cursor), `:query` (a parsed `Conveyor.Query` AST) with `:now` as the
  reference time for relative dates.
  """
  @spec list(keyword()) :: [Invocation.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Invocation
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_projects(Keyword.get(opts, :project_ids, :all))
    |> maybe_where(:status, opts[:status])
    |> maybe_statuses(opts[:statuses])
    |> maybe_query(opts[:query], opts[:now] || DateTime.utc_now())
    |> maybe_before(opts[:before])
    |> order_by([i], desc: i.started_at, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [i], field(i, ^field) == ^value)

  @doc "Restricts a query on a table with `project_id` to `:all` or a list of project ids."
  @spec maybe_projects(Ecto.Query.t(), :all | [integer()]) :: Ecto.Query.t()
  def maybe_projects(query, :all), do: query
  def maybe_projects(query, ids) when is_list(ids), do: where(query, [i], i.project_id in ^ids)

  defp maybe_query(query, nil, _now), do: query
  defp maybe_query(query, [], _now), do: query
  defp maybe_query(query, ast, now), do: where(query, ^Conveyor.Query.to_dynamic(ast, now: now))

  defp maybe_statuses(query, nil), do: query
  defp maybe_statuses(query, statuses), do: where(query, [i], i.status in ^statuses)

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, {started_at, id}),
    do:
      where(
        query,
        [i],
        i.started_at < ^started_at or (i.started_at == ^started_at and i.id < ^id)
      )

  @spec targets(Invocation.t() | String.t()) :: [Target.t()]
  def targets(inv),
    do: Repo.all(from t in Target, where: t.invocation_id == ^id(inv), order_by: t.label)

  @spec failed_targets(Invocation.t() | String.t()) :: [Target.t()]
  def failed_targets(inv) do
    Repo.all(
      from t in Target,
        where:
          t.invocation_id == ^id(inv) and
            (t.status == "failed" or
               t.test_status in [
                 "FAILED",
                 "TIMEOUT",
                 "FLAKY",
                 "INCOMPLETE",
                 "REMOTE_FAILURE",
                 "FAILED_TO_BUILD"
               ]),
        order_by: t.label
    )
  end

  @spec slowest_tests(Invocation.t() | String.t(), pos_integer()) :: [TestResult.t()]
  def slowest_tests(inv, limit \\ 10) do
    Repo.all(
      from t in TestResult,
        where: t.invocation_id == ^id(inv) and not is_nil(t.duration_ms),
        order_by: [desc: t.duration_ms],
        limit: ^limit
    )
  end

  @doc "One page of decoded raw events with their sequence numbers: `{events, total}`."
  @spec events_page(Invocation.t(), pos_integer(), pos_integer()) ::
          {[{pos_integer(), BuildEventStream.BuildEvent.t()}], non_neg_integer()}
  def events_page(%Invocation{} = inv, page, per_page) do
    {frames, total} = RawStore.events_page(inv, page, per_page)

    {Enum.map(frames, fn {seq, frame} -> {seq, BuildEventStream.BuildEvent.decode(frame)} end),
     total}
  end

  @spec test_results(Invocation.t() | String.t()) :: [TestResult.t()]
  def test_results(inv),
    do:
      Repo.all(
        from t in TestResult,
          where: t.invocation_id == ^id(inv),
          order_by: [t.label, t.run, t.shard, t.attempt]
      )

  @spec actions(Invocation.t() | String.t()) :: [Action.t()]
  def actions(inv),
    do: Repo.all(from a in Action, where: a.invocation_id == ^id(inv), order_by: a.seq)

  @spec metrics(Invocation.t() | String.t()) :: Metrics.t() | nil
  def metrics(inv), do: Repo.get(Metrics, id(inv))

  @doc "Every raw BEP event of an invocation, decoded, in sequence order."
  @spec events(Invocation.t()) :: [BuildEventStream.BuildEvent.t()]
  def events(%Invocation{} = inv),
    do: inv |> RawStore.frames() |> Enum.map(&BuildEventStream.BuildEvent.decode/1)

  @doc "The full build log as one string (stdout and stderr interleaved as received)."
  @spec log(Invocation.t()) :: String.t()
  def log(%Invocation{} = inv),
    do: RawStore.log(inv).chunks |> Enum.to_list() |> IO.iodata_to_binary()

  # The readers below answer through `Conveyor.RawStore`; they remain for their callers in
  # the tests until those move to the store's contract suite.

  @doc false
  def raw_frames(%Invocation{} = inv), do: RawStore.frames(inv)

  @doc false
  def archived?(%Invocation{raw_status: "archived", raw_blob: blob}) when is_binary(blob),
    do: true

  def archived?(%Invocation{}), do: false

  @doc false
  def stream_raw(%Invocation{} = inv), do: RawStore.bep(inv)

  @doc false
  def stream_log(%Invocation{} = inv), do: RawStore.log(inv).chunks

  @doc false
  def log_segments(%Invocation{} = inv) do
    cond do
      not archived?(inv) -> log_segment_rows(inv)
      inv.log_bytes == 0 -> []
      true -> [archived_log_segment(inv)]
    end
  end

  defp archived_log_segment(%Invocation{} = inv) do
    %LogSegment{
      first_seq: 1,
      last_seq: inv.last_event_seq,
      byte_offset: 0,
      line_offset: 0,
      byte_size: inv.log_bytes,
      line_count: inv.log_lines
    }
  end

  defp log_segment_rows(%Invocation{id: id} = inv) do
    Repo.all(
      from s in LogSegment,
        where: s.invocation_id == ^id and s.day == ^day(inv),
        order_by: s.first_seq,
        select: %LogSegment{
          first_seq: s.first_seq,
          last_seq: s.last_seq,
          byte_offset: s.byte_offset,
          line_offset: s.line_offset,
          byte_size: s.byte_size,
          line_count: s.line_count
        }
    )
  end

  @doc "Recomputes a project's tag facet counts from its invocations (after bulk deletes or reshaping)."
  @spec rebuild_tag_keys!(integer()) :: :ok
  def rebuild_tag_keys!(project_id) do
    Repo.query!("DELETE FROM tag_keys WHERE project_id = $1", [project_id])

    Repo.query!(
      """
      INSERT INTO tag_keys (project_id, key, value, count, last_seen_at)
      SELECT $1, t.key, t.value, count(*), max(i.started_at)
      FROM invocations i, jsonb_each_text(i.tags) AS t
      WHERE i.project_id = $1
      GROUP BY t.key, t.value
      """,
      [project_id]
    )

    :ok
  end

  @spec tag_keys(integer(), keyword()) :: [TagKey.t()]
  def tag_keys(project_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Repo.all(
      from t in TagKey,
        where: t.project_id == ^project_id,
        order_by: [asc: t.key, desc: t.count, asc: t.value],
        limit: ^limit
    )
  end

  @doc """
  Tag facets: every key with its most common values and counts, most used keys first.
  `project_id` nil aggregates across the projects in `:project_ids` (default `:all`).
  """
  @spec facets(integer() | nil, keyword()) :: [
          %{key: String.t(), total: integer(), values: [{String.t(), integer()}]}
        ]
  def facets(project_id, opts \\ []) do
    per_key = Keyword.get(opts, :values, 8)
    max_keys = Keyword.get(opts, :keys, 30)

    TagKey
    |> maybe_where(:project_id, project_id)
    |> maybe_projects(Keyword.get(opts, :project_ids, :all))
    |> where([t], t.value != "")
    |> group_by([t], [t.key, t.value])
    |> select([t], {t.key, t.value, type(sum(t.count), :integer)})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, v, c} -> {v, c} end)
    |> Enum.map(fn {key, values} ->
      sorted = Enum.sort_by(values, &elem(&1, 1), :desc)

      %{
        key: key,
        total: values |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
        values: Enum.take(sorted, per_key),
        more: max(length(sorted) - per_key, 0)
      }
    end)
    |> Enum.sort_by(&{-&1.total, &1.key})
    |> Enum.take(max_keys)
  end

  @doc """
  The partition day of an invocation: the day its row was created. It must never change
  once segments are written (`started_at` does change when the Started event arrives).
  """
  @spec day(Invocation.t()) :: Date.t()
  def day(%Invocation{inserted_at: %DateTime{} = at}), do: DateTime.to_date(at)
  def day(%Invocation{}), do: Date.utc_today()

  # The codec lives in `Conveyor.RawStore.Codec`; these remain for their callers in the
  # tests until those move to the store's contract suite.

  @doc false
  defdelegate compress(iodata), to: RawStore.Codec
  @doc false
  defdelegate compress_bep(iodata), to: RawStore.Codec
  @doc false
  defdelegate decompress(binary), to: RawStore.Codec

  defp id(%Invocation{id: id}), do: id
  defp id(id) when is_binary(id), do: id
end
