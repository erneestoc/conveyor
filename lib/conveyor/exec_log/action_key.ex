defmodule Conveyor.ExecLog.ActionKey do
  @moduledoc """
  The identity of an action across machines, and the first execution of each one.

  ## The key

  The compact execution log carries the remote-execution **action digest** of a spawn
  (`ExecLogEntry.Spawn.digest`, `spawn.proto`): the hash Bazel looks the action up by in a
  remote or disk cache. Bazel fills it only when a remote executor, a remote cache or a
  disk cache was enabled for the spawn. When it is there, its 32 bytes are the key
  (`key_source` 0): two executions with the same key are by definition one cache entry.

  When it is absent the key is Conveyor's own (`key_source` 1): SHA-256 over the command
  line, the environment (sorted), the platform properties (sorted), the declared output
  paths and `inputs_digest` (every input path with its content digest, tools included).
  Those are the parts of the remote-execution `Action` that differ between two actions of
  one build setup; what Bazel's digest also covers and this key does not is the same for
  every action of a fleet configured alike (the timeout, the cache salt, default
  execution properties, the digest function). Equal fallback keys therefore mean "one
  shared cache entry" under the assumption that the fleet runs one Bazel configuration;
  a key of one source never equals a key of the other, so a project whose logs mix the
  two finds no duplicates between them.

  ## The row

  `action_keys` holds, per scope and key, the execution that finished first: the minimum
  of `(finish, start, invocation, ordinal)` over every execution merged so far. A minimum
  is commutative, associative and idempotent, so the row is the same whatever order logs
  are parsed in and however two parsers interleave (docs/spec/ActionKeys.tla).
  `last_finish` (a maximum) drives retention; `multi` says executions came from more than
  one project (`grp` is the first one seen), `nondet` that they produced more than one set
  of outputs: both are "at least two distinct values seen", kept as one value and a flag.

  ## Scopes

  A scope is where one cache should have been shared: a project by itself (scope = its
  id), and, when the project belongs to a cache group (`Conveyor.Rbe.Groups`), the group
  (scope = minus the group's id). A grouped project's executions are merged into both, so
  a duplicate can be told apart: redone inside the project, or only another project of
  the group had finished it (`classify/4`).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "action_keys" do
    field :scope, :integer, primary_key: true
    field :key, :binary, primary_key: true
    field :first_finish, :utc_datetime_usec
    field :first_start, :utc_datetime_usec
    field :first_invocation_id, Ecto.UUID
    field :first_ordinal, :integer
    field :last_finish, :utc_datetime_usec
    field :grp, :integer
    field :multi, :boolean, default: false
    field :out, :integer
    field :nondet, :boolean, default: false
  end

  @bazel 0
  @fallback 1

  @doc "Names of the key sources, by their stored number."
  @spec source_name(integer() | nil) :: String.t()
  def source_name(@bazel), do: "bazel"
  def source_name(@fallback), do: "fallback"
  def source_name(_), do: "none"

  @doc """
  The key of a spawn entry and its source: Bazel's action digest when the log has it, the
  fallback otherwise.
  """
  @spec of(struct(), String.t(), [String.t()]) :: {binary(), 0 | 1}
  def of(spawn, inputs_digest, output_paths) do
    case spawn.digest do
      %{hash: hash} when byte_size(hash) > 0 ->
        case Base.decode16(hash, case: :mixed) do
          {:ok, bytes} -> {bytes, @bazel}
          :error -> {:crypto.hash(:sha256, ["bazel-digest\0", hash]), @bazel}
        end

      _ ->
        {fallback(spawn, inputs_digest, output_paths), @fallback}
    end
  end

  # Every field is length-prefixed, so no two different actions serialize alike.
  defp fallback(spawn, inputs_digest, output_paths) do
    env = spawn.env_vars |> Enum.map(&{&1.name, &1.value}) |> Enum.sort()

    platform =
      ((spawn.platform && spawn.platform.properties) || [])
      |> Enum.map(&{&1.name, &1.value})
      |> Enum.sort()

    :crypto.hash(:sha256, [
      "conveyor-action-key-v1\0",
      list(spawn.args),
      list(Enum.flat_map(env, &Tuple.to_list/1)),
      list(Enum.flat_map(platform, &Tuple.to_list/1)),
      list(Enum.sort(output_paths)),
      inputs_digest
    ])
  end

  defp list(items),
    do: [<<length(items)::32>> | Enum.map(items, &[<<byte_size(&1)::32>>, &1])]

  @doc """
  Whether a parsed spawn is an execution a cache could have served: it ran (not a cache
  hit), succeeded, may be cached remotely, and the log says when it started.
  """
  @spec execution?(map()) :: boolean()
  def execution?(s) do
    not s.cache_hit and s.exit_code == 0 and is_nil(s.status) and s.cacheable == true and
      s.remote_cacheable == true and not is_nil(s.started_at) and is_binary(s.action_key)
  end

  @doc "When an execution's result existed: its start plus the spawn's total time."
  @spec finish(map()) :: DateTime.t()
  def finish(%{started_at: at} = s),
    do: DateTime.add(at, s.total_ms || s.exec_ms || 0, :millisecond)

  @doc "The order executions of one key are ranked in: the smallest is the first."
  @spec rank(map(), String.t()) :: tuple()
  def rank(s, invocation_id) do
    {DateTime.to_unix(finish(s), :microsecond), DateTime.to_unix(s.started_at, :microsecond),
     invocation_id, s.ordinal}
  end

  @doc """
  The class of one execution against the first of its key in one scope (the definition the
  hourly rollup applies in SQL; this is its executable statement for tests and the model):
  `:first`, `:racing` (it started before the first one finished: only deduplication of
  actions in flight saves it) or `:sequential` (it started after: a shared cache had the
  result).
  """
  @spec classify(map(), String.t(), t() | map() | nil) :: :first | :racing | :sequential
  def classify(_spawn, _invocation_id, nil), do: :first

  def classify(spawn, invocation_id, key) do
    cond do
      key.first_invocation_id == invocation_id and key.first_ordinal == spawn.ordinal -> :first
      DateTime.compare(spawn.started_at, key.first_finish) == :lt -> :racing
      true -> :sequential
    end
  end

  @doc """
  The class of an execution of a grouped project, from its class in the group and in its
  own project: `:sequential` and `:racing` when the project itself had the earlier
  execution, `:sequential_cross` and `:racing_cross` when only another project of the
  group did.
  """
  @spec classify(map(), String.t(), t() | map() | nil, t() | map() | nil) ::
          :first | :racing | :racing_cross | :sequential | :sequential_cross
  def classify(spawn, invocation_id, project_key, group_key) do
    case {classify(spawn, invocation_id, group_key), classify(spawn, invocation_id, project_key)} do
      {:first, _} -> :first
      {:sequential, :sequential} -> :sequential
      {:sequential, _} -> :sequential_cross
      {:racing, :racing} -> :racing
      {:racing, _} -> :racing_cross
    end
  end
end
