defmodule Conveyor.Histogram do
  @moduledoc """
  Fixed-bucket histograms for the Prometheus endpoint, fed by telemetry events.

  `TelemetryMetricsPrometheus.Core` keeps every sample of a `distribution` as a row of an
  ETS bag and only folds the rows into buckets when `/metrics` is scraped: on a node nobody
  scrapes (the trial, the bench) the table grows by one row per acknowledgement and two per
  query, for good, and every sample takes the lock of one hot key. Here a histogram is a
  `:counters` array, one slot per bucket plus the sum: memory is fixed when the histogram is
  defined, an observation is two counter adds whatever the number of scrapes, and nothing
  is locked.

  The interface is `attach/1` (definitions in, handlers attached), `observe/2` and
  `scrape/0` (the same exposition text the library produced, same metric names).

  A definition:

      %{
        name: "conveyor.ingest.ack.latency_us",   # the metric; dots become underscores
        event: [:conveyor, :ingest, :ack],        # the telemetry event
        measurement: :latency_us,                 # the key in its measurements (an integer)
        buckets: [100, 250, ...],                 # upper bounds, in the exported unit
        per_unit: 1,                              # measurement units per exported unit
        description: "...",
        count_as: "conveyor.ingest.ack.count"     # optional: also export the count as a counter
      }

  `per_unit` converts once, at definition time and at scrape time: a duration measured in
  native units and exported in milliseconds has `per_unit` = native units per millisecond,
  and its bounds are compared in native units, so an observation does no arithmetic but
  the comparisons.
  """

  @key __MODULE__

  @type definition :: %{
          required(:name) => String.t(),
          required(:event) => [atom()],
          required(:measurement) => atom(),
          required(:buckets) => [pos_integer(), ...],
          optional(:per_unit) => pos_integer(),
          optional(:description) => String.t(),
          optional(:count_as) => String.t(),
          optional(:count_description) => String.t()
        }

  @doc """
  Defines the histograms and attaches one telemetry handler per event. Calling it again
  (a supervisor restart) keeps the counts of the histograms already defined.
  """
  @spec attach([definition()]) :: :ok
  def attach(definitions) do
    known = :persistent_term.get(@key, %{})

    histograms =
      Map.new(definitions, fn definition ->
        per_unit = Map.get(definition, :per_unit, 1)
        buckets = definition.buckets

        ref =
          case known do
            %{^definition => %{ref: ref}} -> ref
            _ -> :counters.new(length(buckets) + 2, [:write_concurrency])
          end

        {definition,
         %{
           ref: ref,
           bounds: buckets |> Enum.map(&(&1 * per_unit)) |> List.to_tuple(),
           per_unit: per_unit
         }}
      end)

    :persistent_term.put(@key, histograms)

    histograms
    |> Enum.group_by(fn {definition, _} -> definition.event end, fn {definition, h} ->
      {definition.measurement, h.bounds, h.ref}
    end)
    |> Enum.each(fn {event, targets} ->
      id = {__MODULE__, event}
      :telemetry.detach(id)
      :ok = :telemetry.attach(id, event, &__MODULE__.handle_event/4, targets)
    end)
  end

  @doc false
  def handle_event(_event, measurements, _metadata, targets) do
    Enum.each(targets, fn {key, bounds, ref} ->
      case measurements do
        %{^key => value} when is_integer(value) -> add(ref, bounds, value)
        %{^key => value} when is_float(value) -> add(ref, bounds, round(value))
        _ -> :ok
      end
    end)
  end

  @doc "Records one value (in measurement units) in the named histogram."
  @spec observe(String.t(), integer()) :: :ok
  def observe(name, value) when is_integer(value) do
    {_definition, h} =
      Enum.find(:persistent_term.get(@key, %{}), fn {definition, _} -> definition.name == name end)

    add(h.ref, h.bounds, value)
  end

  defp add(ref, bounds, value) do
    size = tuple_size(bounds)
    :counters.add(ref, slot(bounds, value, 1, size), 1)
    :counters.add(ref, size + 2, max(value, 0))
  end

  # Slot of the first bound the value does not exceed; `size + 1` is +Inf.
  defp slot(_bounds, _value, i, size) when i > size, do: i
  defp slot(bounds, value, i, _size) when value <= :erlang.element(i, bounds), do: i
  defp slot(bounds, value, i, size), do: slot(bounds, value, i + 1, size)

  @doc """
  The histogram as numbers: cumulative `{upper bound, count}` pairs ending with `"+Inf"`,
  the count and the sum in exported units. `nil` for an unknown name.
  """
  @spec snapshot(String.t()) ::
          %{
            buckets: [{pos_integer() | String.t(), non_neg_integer()}],
            count: integer(),
            sum: number()
          }
          | nil
  def snapshot(name) do
    case Enum.find(:persistent_term.get(@key, %{}), fn {d, _} -> d.name == name end) do
      nil -> nil
      {definition, h} -> read(definition, h)
    end
  end

  defp read(definition, %{ref: ref, per_unit: per_unit}) do
    n = length(definition.buckets)

    {buckets, count} =
      (definition.buckets ++ ["+Inf"])
      |> Enum.with_index(1)
      |> Enum.map_reduce(0, fn {bound, i}, total ->
        total = total + :counters.get(ref, i)
        {{bound, total}, total}
      end)

    sum = :counters.get(ref, n + 2)
    %{buckets: buckets, count: count, sum: if(per_unit == 1, do: sum, else: sum / per_unit)}
  end

  @doc "Prometheus exposition text of every histogram, in name order."
  @spec scrape() :: String.t()
  def scrape do
    :persistent_term.get(@key, %{})
    |> Enum.sort_by(fn {definition, _} -> definition.name end)
    |> Enum.map_join("", fn {definition, h} ->
      name = String.replace(definition.name, ".", "_")
      %{buckets: buckets, count: count, sum: sum} = read(definition, h)

      [
        "# HELP #{name} #{Map.get(definition, :description, "")}\n",
        "# TYPE #{name} histogram\n",
        Enum.map(buckets, fn {bound, n} -> ~s(#{name}_bucket{le="#{bound}"} #{n}\n) end),
        "#{name}_sum #{sum}\n#{name}_count #{count}\n\n",
        count_as(definition, count)
      ]
      |> IO.iodata_to_binary()
    end)
  end

  # The observation count under a counter's name of its own: the library's counter for the
  # same event is one ETS row every scheduler updates, which a histogram already counts.
  defp count_as(%{count_as: name} = definition, count) do
    name = String.replace(name, ".", "_")

    "# HELP #{name} #{Map.get(definition, :count_description, "")}\n# TYPE #{name} counter\n#{name} #{count}\n\n"
  end

  defp count_as(_definition, _count), do: ""

  @doc "Sets every histogram back to zero (tests)."
  @spec reset() :: :ok
  def reset do
    Enum.each(:persistent_term.get(@key, %{}), fn {definition, %{ref: ref}} ->
      for i <- 1..(length(definition.buckets) + 2), do: :counters.put(ref, i, 0)
    end)
  end
end
