defmodule Conveyor.Invocations do
  @moduledoc "Read side of invocations: list, detail, events, log, targets, tests, actions."
  import Ecto.Query

  alias Conveyor.Bep.Fixture

  alias Conveyor.Invocations.{
    Action,
    EventSegment,
    Invocation,
    LogSegment,
    Metrics,
    NamedSet,
    TagKey,
    Target,
    TestResult
  }

  alias Conveyor.Repo

  @spec get(String.t()) :: Invocation.t() | nil
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Invocation, uuid)
      :error -> nil
    end
  end

  @spec get!(String.t()) :: Invocation.t()
  def get!(id), do: Repo.get!(Invocation, id)

  @doc """
  Newest-first page of invocations. Options: `:project_id`, `:status`, `:statuses` (list),
  `:limit` (default 50), `:before` (`{started_at, id}` cursor).
  """
  @spec list(keyword()) :: [Invocation.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Invocation
    |> maybe_where(:project_id, opts[:project_id])
    |> maybe_where(:status, opts[:status])
    |> maybe_statuses(opts[:statuses])
    |> maybe_before(opts[:before])
    |> order_by([i], desc: i.started_at, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [i], field(i, ^field) == ^value)

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
    frames = raw_frames(inv)
    total = length(frames)

    events =
      frames
      |> Enum.with_index(1)
      |> Enum.slice((page - 1) * per_page, per_page)
      |> Enum.map(fn {frame, seq} -> {seq, BuildEventStream.BuildEvent.decode(frame)} end)

    {events, total}
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

  @spec named_sets(Invocation.t() | String.t()) :: %{String.t() => NamedSet.t()}
  def named_sets(inv) do
    Repo.all(from n in NamedSet, where: n.invocation_id == ^id(inv)) |> Map.new(&{&1.set_id, &1})
  end

  @doc "Every raw BEP event of an invocation, decoded, in sequence order."
  @spec events(Invocation.t()) :: [BuildEventStream.BuildEvent.t()]
  def events(%Invocation{} = inv),
    do: inv |> raw_frames() |> Enum.map(&BuildEventStream.BuildEvent.decode/1)

  @doc "Raw protobuf frames of every BEP event, in sequence order."
  @spec raw_frames(Invocation.t()) :: [binary()]
  def raw_frames(%Invocation{id: id} = inv) do
    from(s in EventSegment,
      where: s.invocation_id == ^id and s.day == ^day(inv),
      order_by: s.first_seq,
      select: s.payload
    )
    |> Repo.all()
    |> Enum.flat_map(&(&1 |> decompress() |> Fixture.frames()))
  end

  @doc "The full build log as one string (stdout and stderr interleaved as received)."
  @spec log(Invocation.t()) :: String.t()
  def log(%Invocation{id: id} = inv) do
    from(s in LogSegment,
      where: s.invocation_id == ^id and s.day == ^day(inv),
      order_by: s.first_seq,
      select: s.data
    )
    |> Repo.all()
    |> Enum.map(&decompress/1)
    |> IO.iodata_to_binary()
  end

  @doc "Log segments metadata (offsets) for seeking without decompressing everything."
  @spec log_segments(Invocation.t()) :: [LogSegment.t()]
  def log_segments(%Invocation{id: id} = inv) do
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

  @doc "The partition day of an invocation: its start day, falling back to insertion day."
  @spec day(Invocation.t()) :: Date.t()
  def day(%Invocation{started_at: %DateTime{} = at}), do: DateTime.to_date(at)
  def day(%Invocation{inserted_at: %DateTime{} = at}), do: DateTime.to_date(at)
  def day(%Invocation{}), do: Date.utc_today()

  @doc false
  def compress(iodata), do: iodata |> :zstd.compress() |> IO.iodata_to_binary()
  @doc false
  def decompress(binary), do: binary |> :zstd.decompress() |> IO.iodata_to_binary()

  defp id(%Invocation{id: id}), do: id
  defp id(id) when is_binary(id), do: id
end
