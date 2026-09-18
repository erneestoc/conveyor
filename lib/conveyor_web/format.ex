defmodule ConveyorWeb.Format do
  @moduledoc "Human formatting of durations, sizes, counts and times for the UI."

  @doc "Milliseconds → `1.2s`, `3m 04s`, `1h 02m`, or `—` when unknown."
  @spec duration(integer() | nil) :: String.t()
  def duration(nil), do: "—"
  def duration(ms) when ms < 1_000, do: "#{ms}ms"
  def duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  def duration(ms) when ms < 3_600_000 do
    "#{div(ms, 60_000)}m #{ms |> rem(60_000) |> div(1_000) |> pad()}s"
  end

  def duration(ms), do: "#{div(ms, 3_600_000)}h #{ms |> rem(3_600_000) |> div(60_000) |> pad()}m"

  @doc "Bytes → `12.3 MB`."
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(b) when b < 1_024, do: "#{b} B"
  def bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  def bytes(b) when b < 1_073_741_824, do: "#{Float.round(b / 1_048_576, 1)} MB"
  def bytes(b), do: "#{Float.round(b / 1_073_741_824, 2)} GB"

  @doc "Integers with thousands separators."
  @spec number(integer() | nil) :: String.t()
  def number(nil), do: "—"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "Percentage of `part` over `total`, or nil when undefined."
  @spec percent(integer() | nil, integer() | nil) :: String.t() | nil
  def percent(_part, total) when total in [nil, 0], do: nil
  def percent(nil, _total), do: nil
  def percent(part, total), do: "#{round(part * 100 / total)}%"

  @doc "Remote cache hit rate of an invocation, or nil."
  def cache_hit_rate(%{remote_cache_hits: hits, actions_executed: executed}),
    do: percent(hits, executed)

  @doc "`2m ago`, `3h ago`, `yesterday`, or a date."
  @spec relative(DateTime.t() | nil, DateTime.t()) :: String.t()
  def relative(nil, _now), do: "—"

  def relative(%DateTime{} = at, now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 172_800 -> "yesterday"
      seconds < 30 * 86_400 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  @doc "ISO 8601 string for `datetime` attributes."
  def iso(nil), do: nil
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  @doc "`bazel test //app/... //lib:all` from an invocation."
  def command_line(%{command: command, patterns: patterns}) do
    ["bazel", command || "?" | patterns || []] |> Enum.join(" ")
  end

  @doc "Shortens a label list for display."
  def truncate(nil, _max), do: ""
  def truncate(string, max) when byte_size(string) <= max, do: string
  def truncate(string, max), do: String.slice(string, 0, max - 1) <> "…"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
