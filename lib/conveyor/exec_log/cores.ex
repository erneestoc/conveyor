defmodule Conveyor.ExecLog.Cores do
  @moduledoc """
  How many cores an executed spawn is charged with, so wall time becomes core time.

  The execution log has wall time per spawn and no CPU time. Its only per-action statement
  of cores is the spawn's execution platform (`ExecLogEntry.Spawn.platform`, the
  remote-execution exec properties): the compact log has no field for execution
  requirements, so a `cpu:N` tag or a test size does not reach it. The sources, best first:

    * `3`, **exec property** (exact, per action): a platform property with one of the
      project's names (`Conveyor.Rbe.Settings`, `cores_property`), tried in the
      project's order: the first name the spawn carries with a readable value wins.
      Names match in any case. Built in: `cpu`, `cpus`, `cores`, `num-cpus`,
      `num_cpus`, `EstimatedCPU`, `resources:cpu`. The value reads by the project's
      unit: `cores` (`4`, `0.5`), `millicores` (`4000`) or `auto` (a plain number is
      cores); a value ending in `m` (`4000m`) is millicores under every unit. Set with
      `exec_properties = {"cores": "4"}` on the target or the execution platform.
      Nothing overrides it. It is read when the log is parsed and stored per spawn;
    * `2`, **target tag**: the `cpu:N` tag of the spawn's test target, taken from the
      event stream's `TargetConfigured` (test runner spawns only: that is what the tag
      reserves cores for);
    * `1`, **measured**: `BuildMetrics` reports the CPU time (user + system) of all
      actions of a mnemonic in the build; divided by the wall time of the same mnemonic's
      executions in the log it gives the average cores they used, never less than one
      (an action waiting on I/O still holds a core of an executor);
    * `0`, **default**: one core.

  A project's own `mnemonic → cores` setting replaces the last three when a report is read
  (`Conveyor.Rbe.Settings`), so changing it never needs a re-parse; a rollup keeps the
  exact part apart for that.
  """
  import Ecto.Query

  alias Conveyor.Invocations.{Invocation, Metrics, Target}
  alias Conveyor.Repo

  @default 0
  @measured 1
  @target_tag 2
  @exec_property 3
  @properties ~w(cpu cpus cores num-cpus num_cpus EstimatedCPU resources:cpu)
  @test_mnemonics ["TestRunner"]

  @doc "The name of a stored source number."
  @spec source_name(integer() | nil) :: String.t()
  def source_name(@exec_property), do: "exec property"
  def source_name(@target_tag), do: "target tag"
  def source_name(@measured), do: "measured"
  def source_name(_), do: "default"

  @doc "The stored number of the exact source."
  @spec exact() :: 3
  def exact, do: @exec_property

  @typedoc "How a project declares cores: property names in order, and the value's unit."
  @type property :: %{names: [String.t()], unit: String.t()}

  @doc "The built-in declaration: the names Conveyor has always looked for, unit `auto`."
  @spec default_property() :: property()
  def default_property, do: %{names: @properties, unit: "auto"}

  @doc """
  Milli-cores stated by a spawn's platform properties, or nil. The names are tried in the
  declaration's order; the first one present (in any case) with a readable value wins.
  """
  @spec from_platform(struct() | nil, property()) :: pos_integer() | nil
  def from_platform(platform, property \\ default_property())
  def from_platform(nil, _property), do: nil

  def from_platform(%{properties: properties}, %{names: names, unit: unit}) do
    values = Map.new(Enum.reverse(properties), &{String.downcase(&1.name), &1.value})

    Enum.find_value(names, fn name ->
      case values[String.downcase(name)] do
        nil -> nil
        value -> milli(String.trim(value), unit)
      end
    end)
  end

  # An `m` suffix is millicores whatever the unit says; a plain number reads by the unit.
  defp milli(value, unit) do
    case Float.parse(value) do
      {n, ""} when n > 0 and unit == "millicores" and n <= 1_024_000 -> max(round(n), 1)
      {n, ""} when n > 0 and unit != "millicores" and n <= 1024 -> round(n * 1000)
      {n, "m"} when n > 0 and n <= 1_024_000 -> max(round(n), 1)
      _ -> nil
    end
  end

  @doc "Reads what the event stream knows about the build: target `cpu:N` tags, CPU time per mnemonic."
  @spec context(Invocation.t()) :: %{tags: map(), cpu_ms: map()}
  def context(%Invocation{id: id}) do
    tags =
      Repo.all(
        from t in Target,
          where: t.invocation_id == ^id and not is_nil(t.cpus),
          select: {t.label, t.cpus}
      )
      |> Map.new()

    metrics =
      Repo.one(from m in Metrics, where: m.invocation_id == ^id, select: m.build_metrics)

    %{tags: tags, cpu_ms: cpu_ms(metrics)}
  end

  @doc "CPU milliseconds (user + system) per mnemonic of a stored `BuildMetrics`."
  @spec cpu_ms(map() | nil) :: %{String.t() => number()}
  def cpu_ms(metrics) do
    for %{"mnemonic" => name} = a <- get_in(metrics || %{}, ["actionSummary", "actionData"]) || [],
        ms = seconds(a["userTime"]) + seconds(a["systemTime"]),
        ms > 0,
        into: %{},
        do: {name, ms}
  end

  defp seconds(text) when is_binary(text) do
    case Float.parse(text) do
      {s, _} -> s * 1000
      :error -> 0
    end
  end

  defp seconds(_), do: 0

  @doc "Sets `cores_milli` and `cores_source` on every executed spawn (pure)."
  @spec assign([map()], %{tags: map(), cpu_ms: map()}) :: [map()]
  def assign(spawns, %{tags: tags, cpu_ms: cpu_ms}) do
    wall =
      spawns
      |> Enum.reject(& &1.cache_hit)
      |> Enum.group_by(& &1.mnemonic, &(&1.exec_ms || 0))
      |> Map.new(fn {m, ms} -> {m, Enum.sum(ms)} end)

    Enum.map(spawns, fn s ->
      {cores, source} =
        cond do
          s.cache_hit ->
            {nil, nil}

          is_integer(s[:platform_cores]) ->
            {s.platform_cores, @exec_property}

          s.mnemonic in @test_mnemonics and is_integer(tags[s.target_label]) ->
            {tags[s.target_label] * 1000, @target_tag}

          is_number(cpu_ms[s.mnemonic]) and Map.get(wall, s.mnemonic, 0) > 0 ->
            {max(1000, round(cpu_ms[s.mnemonic] * 1000 / wall[s.mnemonic])), @measured}

          true ->
            {1000, @default}
        end

      s |> Map.delete(:platform_cores) |> Map.merge(%{cores_milli: cores, cores_source: source})
    end)
  end

  @doc "The cores of a `cpu:N` (or `resources:cpu:N`) tag among a target's tags, or nil."
  @spec from_tags([String.t()]) :: pos_integer() | nil
  def from_tags(tags) do
    Enum.find_value(tags, fn tag ->
      with [_, n] <- Regex.run(~r/^(?:resources:)?cpu:(\d+)$/, tag),
           {cores, ""} when cores > 0 and cores <= 1024 <- Integer.parse(n) do
        cores
      else
        _ -> nil
      end
    end)
  end
end
