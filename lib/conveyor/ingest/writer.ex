defmodule Conveyor.Ingest.Writer do
  @moduledoc """
  Group-commit writer. Workers submit batches; every `writer_flush_ms` (or sooner when the
  queue is large) the writer commits all pending batches from many invocations in one
  transaction and notifies each submitter. If the group fails, batches are retried one by
  one so a single fenced invocation cannot block the others.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias Conveyor.Ingest.{Batch, Retry}

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

  defmodule Fenced do
    @moduledoc "Raised when the invocation row no longer matches the batch's expected sequence."
    defexception [:invocation_id, :expected]

    def message(e),
      do: "invocation #{e.invocation_id} fenced: last_event_seq is not #{e.expected}"
  end

  @max_pending 64

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: name(Keyword.fetch!(opts, :shard)))

  def name(shard), do: {:via, Registry, {Conveyor.Ingest.Registry, {:writer, shard}}}

  @doc "Queues a batch; the caller receives `{:batch_committed, ref}` or `{:batch_failed, ref, reason}`."
  @spec submit(GenServer.name(), Batch.t()) :: :ok
  def submit(writer, %Batch{} = batch), do: GenServer.cast(writer, {:submit, batch, self()})

  @impl true
  def init(opts) do
    {:ok, %{shard: opts[:shard], pending: [], timer: nil, flush_ms: config(:writer_flush_ms, 20)}}
  end

  @impl true
  def handle_cast({:submit, batch, from}, state) do
    state = %{state | pending: [{batch, from} | state.pending]}

    cond do
      length(state.pending) >= @max_pending ->
        {:noreply, flush(state)}

      state.timer == nil ->
        {:noreply, %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    pending = Enum.reverse(state.pending)
    started = System.monotonic_time()

    results =
      case commit_group(pending) do
        :ok ->
          Enum.map(pending, fn {batch, from} -> {batch, from, :ok} end)

        {:error, _} ->
          Enum.map(pending, fn {batch, from} -> {batch, from, commit_single(batch)} end)
      end

    Enum.each(results, fn
      {batch, from, :ok} -> send(from, {:batch_committed, batch.ref})
      {batch, from, {:error, reason}} -> send(from, {:batch_failed, batch.ref, reason})
    end)

    :telemetry.execute(
      [:conveyor, :ingest, :writer, :flush],
      %{
        duration: System.monotonic_time() - started,
        batches: length(pending),
        events: Enum.sum(Enum.map(pending, fn {b, _} -> Batch.event_count(b) end))
      },
      %{shard: state.shard}
    )

    %{state | pending: [], timer: nil}
  end

  # A failure anywhere in the group rolls everything back; the caller then retries batch by
  # batch so one bad invocation (typically a fenced one) cannot hold up the others.
  # Transient database errors are retried with backoff first (Conveyor.Ingest.Retry).
  defp commit_group(pending) do
    batches = Enum.map(pending, &elem(&1, 0))
    # Segments are the bulk of every commit: compress them outside the transaction and
    # write the whole group's rows with one statement per table.
    event_rows = batches |> Enum.map(&Batch.event_segment_row/1) |> Enum.reject(&is_nil/1)
    log_rows = batches |> Enum.map(&Batch.log_segment_row/1) |> Enum.reject(&is_nil/1)
    # Tag counts are rows shared by every invocation of a project. Updating them inside the
    # group transaction made every shard queue on the same row locks for the whole commit
    # (measured: >90 % of active backends waiting on tag_keys), so they are merged across the
    # group and applied in one short statement after the commit.
    tag_rows = tag_key_rows(batches)

    result =
      Retry.with_backoff(
        fn ->
          case Repo.transaction(
                 fn ->
                   if event_rows != [],
                     do: Repo.insert_all(EventSegment, event_rows, on_conflict: :nothing)

                   if log_rows != [],
                     do: Repo.insert_all(LogSegment, log_rows, on_conflict: :nothing)

                   Enum.each(batches, &apply_batch!(&1, segments: false, tag_keys: false))
                 end,
                 timeout: 60_000
               ) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end,
        label: "writer group commit"
      )

    if result == :ok, do: count_tag_keys(tag_rows)
    result
  rescue
    e -> {:error, e}
  end

  defp commit_single(batch) do
    Retry.with_backoff(
      fn ->
        case Repo.transaction(fn -> apply_batch!(batch) end, timeout: 60_000) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end,
      label: "writer commit #{batch.invocation_id}"
    )
  rescue
    e in Fenced ->
      {:error, {:fenced, e.expected}}

    e ->
      Logger.error(
        "batch for #{batch.invocation_id} (#{batch.first_seq}..#{batch.last_seq}) failed: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  @doc """
  Applies one batch inside the current transaction. Raises on failure. `segments: false`
  and `tag_keys: false` skip parts the group commit writes for all batches at once.
  """
  @spec apply_batch!(Batch.t(), keyword()) :: :ok
  def apply_batch!(%Batch{} = b, opts \\ []) do
    if Keyword.get(opts, :segments, true) do
      if row = Batch.event_segment_row(b),
        do: Repo.insert_all(EventSegment, [row], on_conflict: :nothing)

      if row = Batch.log_segment_row(b),
        do: Repo.insert_all(LogSegment, [row], on_conflict: :nothing)
    end

    upsert_grouped(Target, b.invocation_id, Map.values(b.targets), [
      :invocation_id,
      :label,
      :aspect
    ])

    upsert_grouped(TestResult, b.invocation_id, Map.values(b.tests), [
      :invocation_id,
      :label,
      :configuration_id,
      :run,
      :shard,
      :attempt
    ])

    if b.actions != [] do
      rows =
        b.actions |> Enum.reverse() |> Enum.map(&Map.put(&1, :invocation_id, b.invocation_id))

      Repo.insert_all(Action, rows,
        on_conflict: :nothing,
        conflict_target: [:invocation_id, :seq]
      )
    end

    if b.named_sets != [] do
      rows =
        b.named_sets |> Enum.reverse() |> Enum.map(&Map.put(&1, :invocation_id, b.invocation_id))

      Repo.insert_all(NamedSet, rows,
        on_conflict: :nothing,
        conflict_target: [:invocation_id, :set_id]
      )
    end

    if b.metrics do
      now = DateTime.utc_now()

      row =
        b.metrics
        |> Map.merge(%{invocation_id: b.invocation_id, inserted_at: now, updated_at: now})

      replace = Map.keys(b.metrics) ++ [:updated_at]

      Repo.insert_all(Metrics, [row],
        on_conflict: {:replace, replace},
        conflict_target: [:invocation_id]
      )
    end

    if Keyword.get(opts, :tag_keys, true), do: count_tag_keys!(tag_key_rows([b]))

    update_invocation!(b)
    :ok
  end

  # One tag_keys upsert for a whole group: counts merged per (project, key, value) and rows
  # sorted so concurrent statements lock them in the same order (no deadlocks).
  defp tag_key_rows(batches) do
    now = DateTime.utc_now()

    batches
    |> Enum.reduce(%{}, fn b, acc ->
      Enum.reduce(b.tag_keys, acc, fn {{k, v}, n}, acc ->
        Map.update(acc, {b.project_id, k, v}, n, &(&1 + n))
      end)
    end)
    |> Enum.sort()
    |> Enum.map(fn {{project_id, k, v}, n} ->
      %{project_id: project_id, key: k, value: v, count: n, last_seen_at: now}
    end)
  end

  defp count_tag_keys!([]), do: :ok

  defp count_tag_keys!(rows) do
    on_conflict =
      from t in TagKey,
        update: [
          inc: [count: fragment("EXCLUDED.count")],
          set: [last_seen_at: fragment("EXCLUDED.last_seen_at")]
        ]

    Repo.insert_all(TagKey, rows,
      on_conflict: on_conflict,
      conflict_target: [:project_id, :key, :value]
    )

    :ok
  end

  # After a group commit. The batches are already durable and acked, so a failure here is
  # logged rather than turned into a retry of the group; the counts are facet hints.
  defp count_tag_keys(rows) do
    Retry.with_backoff(fn -> count_tag_keys!(rows) end, label: "tag counts")
  rescue
    e ->
      Logger.warning("tag counts not updated for #{length(rows)} rows: #{Exception.message(e)}")
      :ok
  end

  # Compare-and-set on last_event_seq fences stale workers (another node or a restart).
  defp update_invocation!(%Batch{} = b) do
    expected = b.first_seq - 1
    sets = b.invocation |> Map.take(Invocation.ingest_fields()) |> Map.to_list()

    sets =
      Keyword.merge(sets,
        last_event_seq: b.last_seq,
        last_event_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      )

    query =
      from i in Invocation, where: i.id == ^b.invocation_id and i.last_event_seq == ^expected

    case Repo.update_all(query, set: sets) do
      {1, _} -> :ok
      {0, _} -> raise Fenced, invocation_id: b.invocation_id, expected: expected
    end
  end

  # Rows in one insert_all must share a key set, so group by the fields present and
  # replace exactly those on conflict: partial updates without reading current rows.
  defp upsert_grouped(_schema, _invocation_id, [], _conflict_target), do: :ok

  defp upsert_grouped(schema, invocation_id, rows, conflict_target) do
    rows
    |> Enum.map(&Map.put(&1, :invocation_id, invocation_id))
    |> Enum.group_by(&(&1 |> Map.keys() |> Enum.sort()))
    |> Enum.each(fn {keys, group} ->
      replace = keys -- conflict_target
      on_conflict = if replace == [], do: :nothing, else: {:replace, replace}
      Repo.insert_all(schema, group, on_conflict: on_conflict, conflict_target: conflict_target)
    end)
  end

  defp config(key, default), do: Application.get_env(:conveyor, Conveyor.Ingest)[key] || default
end
