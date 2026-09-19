defmodule Conveyor.Query.Values do
  @moduledoc "Parses typed values used by the query language: durations, dates, numbers."

  @doc "`5m`, `2h30m`, `500ms`, `1.5s`; a bare number is seconds. Returns milliseconds."
  @spec duration(String.t()) :: {:ok, integer()} | :error
  def duration(string) do
    case Regex.scan(~r/(\d+(?:\.\d+)?)(ms|h|m|s|d)?/, String.downcase(string),
           capture: :all_but_first
         ) do
      [] ->
        :error

      parts ->
        if Enum.join(Enum.map(parts, &Enum.join/1)) != String.downcase(string) do
          :error
        else
          {:ok,
           Enum.reduce(parts, 0, fn [n | unit], acc ->
             {value, _} = Float.parse(n)
             acc + round(value * unit_ms(List.first(unit) || "s"))
           end)}
        end
    end
  end

  defp unit_ms("ms"), do: 1
  defp unit_ms("s"), do: 1_000
  defp unit_ms("m"), do: 60_000
  defp unit_ms("h"), do: 3_600_000
  defp unit_ms("d"), do: 86_400_000

  @doc "ISO date, ISO datetime, or relative like `-24h`, `-7d`, `-30m` (from `now`)."
  @spec datetime(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | :error
  def datetime("-" <> rel, now) do
    case duration(rel) do
      {:ok, ms} -> {:ok, DateTime.add(now, -div(ms, 1_000), :second)}
      :error -> :error
    end
  end

  def datetime(string, _now) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(string) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          _ -> :error
        end
    end
  end

  @doc "Integer or float."
  @spec number(String.t()) :: {:ok, number()} | :error
  def number(string) do
    case Integer.parse(string) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(string) do
          {f, ""} -> {:ok, f}
          _ -> :error
        end
    end
  end

  @doc "Whether a string looks numeric (used for tag comparisons)."
  def numeric?(string), do: match?({:ok, _}, number(string))
end
