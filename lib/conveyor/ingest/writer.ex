defmodule Conveyor.Ingest.Writer do
  @moduledoc """
  Group-commit writer. Workers submit batches; every `writer_flush_ms` (or sooner when the
  queue is large) the writer commits all pending batches from many invocations in one
  transaction and notifies each submitter. If the group fails, batches are retried one by
  one so a single fenced invocation cannot block the others.

  Inside the transaction the group is written table by table: one statement per table and
  column set for segments, targets, tests, actions, named sets and metrics, then one fenced
  invocation update per set of dirty columns (`UPDATE … FROM unnest(...)`, PLAN §24 item 1).
  Batches of one invocation that follow each other are merged first, so an invocation
  costs one segment, one log row and one update row per flush however many batches it
  submitted. Round trips grow with the number of tables, not batches.
  """
  use GenServer

  require Logger

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
    {:ok,
     %{
       shard: opts[:shard],
       pending: [],
       count: 0,
       timer: nil,
       flush_ms: config(:writer_flush_ms, 20),
       max_pending: config(:writer_max_pending, 256)
     }}
  end

  @impl true
  def handle_cast({:submit, batch, from}, state) do
    state = %{state | pending: [{batch, from} | state.pending], count: state.count + 1}

    cond do
      state.count >= state.max_pending ->
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

    %{state | pending: [], count: 0, timer: nil}
  end

  # A failure anywhere in the group rolls everything back; the caller then retries batch by
  # batch so one bad invocation (typically a fenced one) cannot hold up the others.
  # Transient database errors are retried with backoff first (Conveyor.Ingest.Retry).
  defp commit_group(pending) do
    units = pending |> Enum.map(&elem(&1, 0)) |> Batch.coalesce()
    plan = plan(units)

    result =
      Retry.with_backoff(
        fn ->
          case Repo.transaction(fn -> apply_plan!(plan, units) end, timeout: 60_000) do
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
    e ->
      # The group is redone batch by batch; count it, a fenced batch in every flush would
      # double the write cost silently otherwise.
      :telemetry.execute([:conveyor, :ingest, :writer, :group_failed], %{count: 1}, %{
        batches: length(pending),
        reason: Exception.message(e)
      })

      {:error, e}
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
      :telemetry.execute([:conveyor, :ingest, :fenced], %{count: 1}, %{
        invocation_id: batch.invocation_id
      })

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
    update_invocations!(batches)
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
  # Batches that set the same columns share one statement: the rows travel as parallel
  # arrays through unnest, and an id missing from RETURNING is a fenced batch. One statement
  # must not touch an invocation twice (the row it would see is undefined), so batches of
  # the same invocation left separate by `Batch.coalesce/1` go in successive rounds.
  defp update_invocations!(batches) do
    now = DateTime.utc_now()

    batches
    |> Enum.group_by(&dirty_columns/1)
    |> Enum.each(fn {columns, group} ->
      group |> unique_rounds() |> Enum.each(&fenced_update!(columns, &1, now))
    end)
  end

  defp dirty_columns(%Batch{invocation: changes}),
    do: changes |> Map.take(Invocation.ingest_fields()) |> Map.keys() |> Enum.sort()

  defp unique_rounds([]), do: []

  defp unique_rounds(batches) do
    {round, rest} =
      Enum.reduce(batches, {[], []}, fn b, {round, rest} ->
        if Enum.any?(round, &(&1.invocation_id == b.invocation_id)),
          do: {round, [b | rest]},
          else: {[b | round], rest}
      end)

    [Enum.reverse(round) | unique_rounds(Enum.reverse(rest))]
  end

  @fixed [{"id", "uuid"}, {"expected", "bigint"}, {"last_seq", "bigint"}, {"now", "timestamptz"}]

  defp fenced_update!(columns, batches, now) do
    typed = Enum.map(columns, &{Atom.to_string(&1), Invocation.__schema__(:type, &1)})

    params =
      [
        Enum.map(batches, &Ecto.UUID.dump!(&1.invocation_id)),
        Enum.map(batches, &(&1.first_seq - 1)),
        Enum.map(batches, & &1.last_seq),
        Enum.map(batches, fn _ -> now end)
      ] ++
        Enum.map(typed, fn {name, type} ->
          col = String.to_existing_atom(name)
          Enum.map(batches, &param_value(Map.get(&1.invocation, col), type))
        end)

    unnest =
      (@fixed ++ Enum.map(typed, fn {name, type} -> {name, array_type(type)} end))
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{_name, type}, i} -> "$#{i}::#{type}[]" end)

    names = Enum.map_join(@fixed ++ typed, ", ", fn {name, _} -> ~s("#{name}") end)

    sets =
      [
        ~s("last_event_seq" = u."last_seq"),
        ~s("last_event_at" = u."now"),
        ~s("updated_at" = u."now")
      ] ++ Enum.map(typed, fn {name, type} -> ~s("#{name}" = #{column_value(name, type)}) end)

    sql = """
    UPDATE "invocations" AS i SET #{Enum.join(sets, ", ")}
    FROM unnest(#{unnest}) AS u(#{names})
    WHERE i."id" = u."id" AND i."last_event_seq" = u."expected"
    RETURNING i."id"
    """

    # A named prepared statement per column set: unnamed statements are parsed and planned
    # on every call (measured: planning cost more than execution).
    name = "conveyor_fenced_update_" <> Base.encode16(:erlang.md5(sql), case: :lower)
    %{rows: rows} = Repo.query!(sql, params, cache_statement: name)
    updated = MapSet.new(rows, fn [id] -> id end)

    case Enum.find(batches, &(not MapSet.member?(updated, Ecto.UUID.dump!(&1.invocation_id)))) do
      nil -> :ok
      b -> raise Fenced, invocation_id: b.invocation_id, expected: b.first_seq - 1
    end
  end

  # Element types of the unnest arrays per Ecto type. A list inside an array parameter
  # would be a nested array, so array columns travel as JSON text and are unpacked in SQL.
  defp array_type(:string), do: "text"
  defp array_type(:integer), do: "bigint"
  defp array_type(:boolean), do: "boolean"
  defp array_type(:map), do: "jsonb"
  defp array_type(:utc_datetime_usec), do: "timestamptz"
  defp array_type({:array, :string}), do: "text"

  defp param_value(nil, _type), do: nil
  defp param_value(list, {:array, :string}), do: Jason.encode!(list)
  defp param_value(value, _type), do: value

  defp column_value(name, {:array, :string}),
    do:
      ~s[CASE WHEN u."#{name}" IS NULL THEN NULL ELSE ARRAY(SELECT jsonb_array_elements_text(u."#{name}"::jsonb)) END]

  defp column_value(name, _type), do: ~s(u."#{name}")

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
