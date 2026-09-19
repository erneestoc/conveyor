defmodule Conveyor.Ingest.Writer do
  @moduledoc """
  Group-commit writer. Workers submit batches; every `writer_flush_ms` (or sooner when the
  queue is large) the writer commits all pending batches from many invocations in one
  transaction and notifies each submitter. If the group fails, batches are retried one by
  one so a single fenced invocation cannot block the others.

  Inside the transaction the group is written table by table: one statement per table and
  column set for segments, targets, tests, actions, named sets and metrics, then one fenced
  invocation update per batch. Round trips grow with the number of tables, not batches.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias Conveyor.Ingest.{Batch, Retry, TagCounter}

  alias Conveyor.Invocations.{
    Action,
    EventSegment,
    Invocation,
    LogSegment,
    Metrics,
    NamedSet,
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
  @target_key [:invocation_id, :label, :aspect]
  @test_key [:invocation_id, :label, :configuration_id, :run, :shard, :attempt]

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
    plan = plan(batches)

    result =
      Retry.with_backoff(
        fn ->
          case Repo.transaction(fn -> apply_plan!(plan, batches) end, timeout: 60_000) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end,
        label: "writer group commit"
      )

    # Tag counts are rows shared by every invocation of a project. Updating them inside the
    # group transaction made every shard queue on the same row locks for the whole commit
    # (measured: >90 % of active backends waiting on tag_keys), so they go to the node's
    # TagCounter after the commit.
    if result == :ok, do: TagCounter.add(plan.tag_counts)
    result
  rescue
    e -> {:error, e}
  end

  defp commit_single(batch) do
    plan = plan([batch])

    result =
      Retry.with_backoff(
        fn ->
          case Repo.transaction(fn -> apply_plan!(plan, [batch]) end, timeout: 60_000) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end,
        label: "writer commit #{batch.invocation_id}"
      )

    if result == :ok, do: TagCounter.add(plan.tag_counts)
    result
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
  The rows every table receives for a group of batches, merged across the batches. Pure and
  computed outside the transaction (segment compression happens here).
  """
  @spec plan([Batch.t()]) :: map()
  def plan(batches) do
    now = DateTime.utc_now()

    %{
      event_rows: batches |> Enum.map(&Batch.event_segment_row/1) |> Enum.reject(&is_nil/1),
      log_rows: batches |> Enum.map(&Batch.log_segment_row/1) |> Enum.reject(&is_nil/1),
      targets: merged_rows(batches, :targets),
      tests: merged_rows(batches, :tests),
      actions: flat_rows(batches, :actions),
      named_sets: flat_rows(batches, :named_sets),
      metrics: metrics_rows(batches, now),
      tag_counts: tag_counts(batches)
    }
  end

  # Writes a planned group inside the current transaction, ending with one fenced update per
  # batch in submission order. Raises on failure.
  defp apply_plan!(plan, batches) do
    if plan.event_rows != [],
      do: Repo.insert_all(EventSegment, plan.event_rows, on_conflict: :nothing)

    if plan.log_rows != [], do: Repo.insert_all(LogSegment, plan.log_rows, on_conflict: :nothing)
    upsert_grouped(Target, plan.targets, @target_key)
    upsert_grouped(TestResult, plan.tests, @test_key)

    if plan.actions != [],
      do:
        Repo.insert_all(Action, plan.actions,
          on_conflict: :nothing,
          conflict_target: [:invocation_id, :seq]
        )

    if plan.named_sets != [],
      do:
        Repo.insert_all(NamedSet, plan.named_sets,
          on_conflict: :nothing,
          conflict_target: [:invocation_id, :set_id]
        )

    upsert_grouped(Metrics, plan.metrics, [:invocation_id], [:inserted_at])
    Enum.each(batches, &update_invocation!/1)
    :ok
  end

  # Keyed rows (targets, tests) merged per invocation and key, later batches over earlier
  # ones: one upsert must not touch the same row twice, and the result must equal applying
  # the batches in order.
  defp merged_rows(batches, field) do
    batches
    |> Enum.reduce(%{}, fn b, acc ->
      Enum.reduce(Map.fetch!(b, field), acc, fn {key, attrs}, acc ->
        Map.update(
          acc,
          {b.invocation_id, key},
          Map.put(attrs, :invocation_id, b.invocation_id),
          &Map.merge(&1, attrs)
        )
      end)
    end)
    |> Map.values()
  end

  defp flat_rows(batches, field) do
    Enum.flat_map(batches, fn b ->
      b
      |> Map.fetch!(field)
      |> Enum.reverse()
      |> Enum.map(&Map.put(&1, :invocation_id, b.invocation_id))
    end)
  end

  defp metrics_rows(batches, now) do
    batches
    |> Enum.reduce(%{}, fn
      %{metrics: nil}, acc -> acc
      b, acc -> Map.update(acc, b.invocation_id, b.metrics, &Map.merge(&1, b.metrics))
    end)
    |> Enum.map(fn {id, metrics} ->
      Map.merge(metrics, %{invocation_id: id, inserted_at: now, updated_at: now})
    end)
  end

  # Counts per (project, key, value) across the group, for the TagCounter.
  defp tag_counts(batches) do
    Enum.reduce(batches, %{}, fn b, acc ->
      Enum.reduce(b.tag_keys, acc, fn {{k, v}, n}, acc ->
        Map.update(acc, {b.project_id, k, v}, n, &(&1 + n))
      end)
    end)
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
  # `keep` columns are written on insert but never replaced.
  defp upsert_grouped(schema, rows, conflict_target, keep \\ [])

  defp upsert_grouped(_schema, [], _conflict_target, _keep), do: :ok

  defp upsert_grouped(schema, rows, conflict_target, keep) do
    rows
    |> Enum.group_by(&(&1 |> Map.keys() |> Enum.sort()))
    |> Enum.each(fn {keys, group} ->
      replace = (keys -- conflict_target) -- keep
      on_conflict = if replace == [], do: :nothing, else: {:replace, replace}
      Repo.insert_all(schema, group, on_conflict: on_conflict, conflict_target: conflict_target)
    end)
  end

  defp config(key, default), do: Application.get_env(:conveyor, Conveyor.Ingest)[key] || default
end
