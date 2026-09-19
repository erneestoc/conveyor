defmodule Conveyor.Ingest.TagCounter do
  @moduledoc """
  Coalesces `tag_keys` counts from every writer on this node and writes them with one upsert
  per `tag_flush_ms`. Those rows are shared by every invocation of a project: updating them
  from each group commit serialized all writer shards on the same row locks. Here they are
  touched once per node per interval, with rows sorted so nodes lock them in the same order.

  Counts are facet hints (autocomplete, ordering); a flush that still fails after the
  transient-error retries is logged and dropped rather than blocking ingest.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias Conveyor.Ingest.Retry
  alias Conveyor.Invocations.TagKey
  alias Conveyor.Repo

  @type counts :: %{{integer(), String.t(), String.t()} => pos_integer()}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Adds counts keyed by `{project_id, key, value}`."
  @spec add(GenServer.server(), counts()) :: :ok
  def add(server \\ __MODULE__, counts)
  def add(_server, counts) when map_size(counts) == 0, do: :ok
  def add(server, counts), do: GenServer.cast(server, {:add, counts})

  @doc "Writes the pending counts now (tests and shutdown)."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    flush_ms = Keyword.get(opts, :flush_ms) || config(:tag_flush_ms, 1000)
    {:ok, %{counts: %{}, timer: nil, flush_ms: flush_ms}}
  end

  @impl true
  def handle_cast({:add, counts}, state) do
    merged = Map.merge(state.counts, counts, fn _k, a, b -> a + b end)
    timer = state.timer || Process.send_after(self(), :flush, state.flush_ms)
    {:noreply, %{state | counts: merged, timer: timer}}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, write(%{state | timer: nil})}

  @impl true
  def terminate(_reason, state) do
    write(state)
    :ok
  end

  defp write(%{counts: counts} = state) when map_size(counts) == 0, do: state

  defp write(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    upsert(rows(state.counts))
    %{state | counts: %{}, timer: nil}
  end

  @doc false
  @spec rows(counts()) :: [map()]
  def rows(counts) do
    now = DateTime.utc_now()

    counts
    |> Enum.sort()
    |> Enum.map(fn {{project_id, key, value}, n} ->
      %{project_id: project_id, key: key, value: value, count: n, last_seen_at: now}
    end)
  end

  defp upsert(rows) do
    on_conflict =
      from t in TagKey,
        update: [
          inc: [count: fragment("EXCLUDED.count")],
          set: [last_seen_at: fragment("EXCLUDED.last_seen_at")]
        ]

    Retry.with_backoff(
      fn ->
        Repo.insert_all(TagKey, rows,
          on_conflict: on_conflict,
          conflict_target: [:project_id, :key, :value]
        )
      end,
      label: "tag counts"
    )

    :ok
  rescue
    e ->
      Logger.warning("tag counts not updated for #{length(rows)} rows: #{Exception.message(e)}")
      :ok
  end

  defp config(key, default), do: Application.get_env(:conveyor, Conveyor.Ingest)[key] || default
end
