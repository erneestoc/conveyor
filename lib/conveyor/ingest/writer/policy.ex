defmodule Conveyor.Ingest.Writer.Policy do
  @moduledoc """
  What a writer shard does after each attempt to commit a group: pure, no clock, no
  database. The writer asks `next/1` what to attempt, reports the attempt with `record/2`
  (or takes units out itself with `evict/3`: a deadline), and at `:done` holds one verdict
  per unit.

  A unit is the batches one invocation has in the group, merged, named by its key
  (`Batch.units/1`: the invocation and the unit's position among that invocation's units).
  The units are given in submission order and every attempt keeps that order.

  ## The policy

  | Attempt ended with | Next |
  |---|---|
  | `:committed` | the attempted units are committed |
  | `{:fenced, keys}` | those units, and the later units of their invocations, are `:fenced`; the rest is attempted again at once |
  | `{:error, :unavailable, reason}` (no connection, pool exhausted, the store refused the object) | the same units again after the next retry delay; with no delay left, **every** unit still open fails |
  | `{:error, :contention, reason}` (deadlock, serialization failure) | the same units again after the next retry delay; with no delay left, as `:data` |
  | `{:error, :data, reason}` (anything else: a row the database refuses) | the attempted units are split in two and each half attempted in order; a single unit fails, and the later units of its invocation with it |

  Why. An unavailable database or store is not the fault of a batch: committing the group
  in smaller pieces only adds transactions to a system that is refusing them, so the group
  waits out the delays and then fails as a whole (its streams fail, the clients resend).
  A refused row is the fault of one batch, and halving finds it in about `2·log2(n)`
  transactions where one by one costs `n`. Contention is between this group and another
  transaction, so it is retried, and a group that still deadlocks is halved to shrink the
  locks it takes at once.

  ## The bound

  A group of `n` units starts at most `1 + length(retry_delays) + 2·⌈log2 n⌉ + 1` attempts
  (21 for 256 units and three delays) and sleeps at most `sum(retry_delays)`: one poison
  unit is isolated within that, and when more is wrong than the budget covers, the units
  still open fail with the last error. Retry delays are a budget of the whole group, not
  of each attempt.
  """

  @type key :: Conveyor.Ingest.Batch.unit_key()
  @type verdict :: :committed | :fenced | :expired | {:failed, term()}
  @type outcome ::
          :committed
          | {:fenced, [key()]}
          | {:error, :unavailable | :contention | :data, term()}

  defstruct todo: [], results: %{}, attempts: 0, delays: [], last_error: nil

  @type t :: %__MODULE__{
          todo: [[key()]],
          results: %{key() => verdict()},
          attempts: non_neg_integer(),
          delays: [non_neg_integer()],
          last_error: term()
        }

  @default_delays [50, 200, 800]

  @doc "The policy state of a group: its unit keys in submission order. Option: `:retry_delays`."
  @spec new([key()], keyword()) :: t()
  def new(keys, opts \\ []) do
    delays = Keyword.get(opts, :retry_delays, @default_delays)

    %__MODULE__{
      todo: if(keys == [], do: [], else: [keys]),
      attempts: max_attempts(length(keys), length(delays)),
      delays: delays
    }
  end

  @doc "The most attempts a group of `n` units may start with `retries` retry delays."
  @spec max_attempts(non_neg_integer(), non_neg_integer()) :: pos_integer()
  def max_attempts(n, retries), do: 1 + retries + 2 * ceil_log2(n) + 1

  @doc "The next step: attempt these units in one transaction, or the verdict of every unit."
  @spec next(t()) :: {:attempt, [key()], t()} | {:done, %{key() => verdict()}}
  def next(%__MODULE__{todo: []} = p), do: {:done, p.results}

  def next(%__MODULE__{attempts: 0} = p),
    do: {:done, fail_open(p, p.last_error || :attempts_exhausted).results}

  def next(%__MODULE__{todo: [head | _]} = p),
    do: {:attempt, head, %{p | attempts: p.attempts - 1}}

  @doc "The units without a verdict yet, in order."
  @spec open(t()) :: [key()]
  def open(%__MODULE__{todo: todo}), do: Enum.concat(todo)

  @doc """
  Reports how the attempt `next/1` asked for ended. Returns the new state and how long to
  wait before asking for the next step (a retry delay, or 0).
  """
  @spec record(t(), outcome()) :: {t(), non_neg_integer()}
  def record(%__MODULE__{todo: [head | rest]} = p, :committed),
    do: {%{p | todo: rest, results: verdicts(p.results, head, :committed)}, 0}

  def record(%__MODULE__{} = p, {:fenced, keys}), do: {evict(p, keys, :fenced), 0}

  def record(%__MODULE__{delays: [delay | delays]} = p, {:error, class, reason})
      when class in [:unavailable, :contention],
      do: {%{p | delays: delays, last_error: reason}, delay}

  def record(%__MODULE__{} = p, {:error, :unavailable, reason}), do: {fail_open(p, reason), 0}

  def record(%__MODULE__{todo: [[key] | _]} = p, {:error, _class, reason}),
    do: {evict(%{p | last_error: reason}, [key], {:failed, reason}), 0}

  def record(%__MODULE__{todo: [head | rest]} = p, {:error, _class, reason}) do
    {a, b} = Enum.split(head, div(length(head), 2))
    {%{p | todo: [a, b | rest], last_error: reason}, 0}
  end

  @doc """
  Takes units out with a verdict, and with them the later units of the same invocations:
  those could only be fenced, since their predecessor did not commit.
  """
  @spec evict(t(), [key()], verdict()) :: t()
  def evict(%__MODULE__{} = p, keys, verdict) do
    from = Enum.reduce(keys, %{}, fn {id, n}, acc -> Map.update(acc, id, n, &min(&1, n)) end)
    gone? = fn {id, n} -> is_map_key(from, id) and n >= from[id] end

    {todo, results} =
      Enum.map_reduce(p.todo, p.results, fn group, results ->
        {out, keep} = Enum.split_with(group, gone?)
        {keep, verdicts(results, out, verdict)}
      end)

    %{p | todo: Enum.reject(todo, &(&1 == [])), results: results}
  end

  defp fail_open(p, reason),
    do: %{p | todo: [], results: verdicts(p.results, Enum.concat(p.todo), {:failed, reason})}

  defp verdicts(results, keys, verdict),
    do: Enum.reduce(keys, results, &Map.put(&2, &1, verdict))

  defp ceil_log2(n) when n <= 1, do: 0
  defp ceil_log2(n), do: 1 + ceil_log2(div(n + 1, 2))
end
