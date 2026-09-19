defmodule Conveyor.Profile do
  @moduledoc """
  Streaming reader and summarizer for Bazel JSON profiles (`command.profile.gz`, Chrome
  trace-event format: `{"otherData": {...}, "traceEvents": [...]}`).

  `events/1` turns a stream of (optionally gzipped) binaries into a stream of decoded
  trace events without ever holding the whole file in memory: a byte scanner finds the
  `traceEvents` array and cuts out one JSON object at a time, tracking strings and
  nesting so chunk boundaries can fall anywhere. `summarize/1` folds that stream into the
  per-category / per-mnemonic totals, phases, critical path and longest events shown in
  the UI and stored in `invocation_metrics.profile_summary`.
  """

  @top_n 50
  @keep 20

  @doc "Decoded trace events from a stream of binaries (gzip detected by magic bytes)."
  @spec events(Enumerable.t()) :: Enumerable.t()
  def events(chunks) do
    chunks
    |> gunzip()
    |> objects()
    |> Stream.map(&Jason.decode!/1)
  end

  @doc "Decompresses a gzip stream of binaries; passes plain data through untouched."
  @spec gunzip(Enumerable.t()) :: Enumerable.t()
  def gunzip(chunks) do
    Stream.transform(
      chunks,
      fn -> :undecided end,
      fn
        chunk, :undecided when byte_size(chunk) < 2 ->
          {[], {:undecided, chunk}}

        chunk, {:undecided, head} ->
          decide(head <> chunk)

        chunk, :undecided ->
          decide(chunk)

        chunk, :plain ->
          {[chunk], :plain}

        chunk, {:gzip, z} ->
          {inflate(z, chunk), {:gzip, z}}
      end,
      fn
        {:gzip, z} -> :zlib.close(z)
        _ -> :ok
      end
    )
  end

  defp decide(<<0x1F, 0x8B, _::binary>> = chunk) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 31)
    {inflate(z, chunk), {:gzip, z}}
  end

  defp decide(chunk), do: {[chunk], :plain}

  defp inflate(z, chunk) do
    case :zlib.safeInflate(z, chunk) do
      {:continue, out} -> [IO.iodata_to_binary(out) | inflate(z, "")]
      {:finished, out} -> [IO.iodata_to_binary(out)]
    end
  end

  @doc "Cuts the `traceEvents` array of a JSON stream into one binary per top-level object."
  @spec objects(Enumerable.t()) :: Enumerable.t()
  def objects(chunks) do
    Stream.transform(
      chunks,
      %{mode: :seek, head: "", depth: 0, str: false, esc: false, acc: []},
      fn
        chunk, %{mode: :seek} = st ->
          head = st.head <> chunk

          case :binary.match(head, "\"traceEvents\"") do
            {pos, len} ->
              rest = binary_part(head, pos + len, byte_size(head) - pos - len)

              case :binary.match(rest, "[") do
                {p, 1} ->
                  body = binary_part(rest, p + 1, byte_size(rest) - p - 1)
                  scan(body, %{st | mode: :array, head: ""})

                :nomatch ->
                  {[], %{st | head: head}}
              end

            :nomatch ->
              {[], %{st | head: head}}
          end

        chunk, %{mode: :array} = st ->
          scan(chunk, st)

        _chunk, %{mode: :done} = st ->
          {[], st}
      end
    )
  end

  # Scans one chunk in array mode; returns {objects, state}.
  defp scan(chunk, st), do: scan(chunk, 0, 0, st, [])

  defp scan(chunk, i, start, st, out) when i >= byte_size(chunk) do
    st =
      if st.depth > 0, do: %{st | acc: [st.acc, binary_part(chunk, start, i - start)]}, else: st

    {Enum.reverse(out), st}
  end

  defp scan(chunk, i, start, %{depth: 0} = st, out) do
    case :binary.at(chunk, i) do
      ?{ -> scan(chunk, i + 1, i, %{st | depth: 1, acc: []}, out)
      ?] -> {Enum.reverse(out), %{st | mode: :done}}
      _ -> scan(chunk, i + 1, start, st, out)
    end
  end

  defp scan(chunk, i, start, %{str: true} = st, out) do
    b = :binary.at(chunk, i)

    st =
      cond do
        st.esc -> %{st | esc: false}
        b == ?\\ -> %{st | esc: true}
        b == ?" -> %{st | str: false}
        true -> st
      end

    scan(chunk, i + 1, start, st, out)
  end

  defp scan(chunk, i, start, st, out) do
    case :binary.at(chunk, i) do
      ?" ->
        scan(chunk, i + 1, start, %{st | str: true}, out)

      ?{ ->
        scan(chunk, i + 1, start, %{st | depth: st.depth + 1}, out)

      ?} when st.depth == 1 ->
        object = IO.iodata_to_binary([st.acc, binary_part(chunk, start, i + 1 - start)])
        scan(chunk, i + 1, i + 1, %{st | depth: 0, acc: []}, [object | out])

      ?} ->
        scan(chunk, i + 1, start, %{st | depth: st.depth - 1}, out)

      _ ->
        scan(chunk, i + 1, start, st, out)
    end
  end

  @doc "Folds trace events into the profile summary map (string keys, JSON-friendly)."
  @spec summarize(Enumerable.t()) :: map()
  def summarize(events) do
    acc = %{
      threads: %{},
      cats: %{},
      mnemonics: %{},
      critical: [],
      longest: [],
      longest_n: 0,
      markers: [],
      counters: %{},
      count: 0,
      min_ts: nil,
      max_end: 0
    }

    events |> Enum.reduce(acc, &fold/2) |> finish()
  end

  defp fold(%{"ph" => "M", "name" => "thread_name"} = e, acc) do
    key = {e["pid"], e["tid"]}
    put_in(acc, [:threads, key], get_in(e, ["args", "name"]) || "#{e["tid"]}")
  end

  defp fold(%{"ph" => "X"} = e, acc) do
    ts = num(e["ts"])
    dur = num(e["dur"])
    cat = e["cat"] || "uncategorized"
    args = e["args"] || %{}

    acc =
      acc
      |> Map.update!(:cats, &add_total(&1, cat, dur))
      |> Map.update!(:count, &(&1 + 1))
      |> Map.update!(:min_ts, &min_ts(&1, ts))
      |> Map.update!(:max_end, &max(&1, ts + dur))

    acc =
      case args["mnemonic"] do
        m when is_binary(m) and cat == "action processing" ->
          Map.update!(acc, :mnemonics, &add_total(&1, m, dur))

        _ ->
          acc
      end

    acc =
      if cat == "critical path component",
        do: Map.update!(acc, :critical, &[%{name: e["name"], ts: ts, dur: dur} | &1]),
        else: acc

    acc =
      if cat == "build phase marker",
        do: Map.update!(acc, :markers, &[%{name: e["name"], ts: ts, dur: dur} | &1]),
        else: acc

    longest = [
      %{
        name: e["name"],
        cat: cat,
        ts: ts,
        dur: dur,
        thread: {e["pid"], e["tid"]},
        target: args["target"],
        mnemonic: args["mnemonic"]
      }
      | acc.longest
    ]

    if acc.longest_n + 1 >= @top_n * 4,
      do: %{acc | longest: top(longest), longest_n: @top_n},
      else: %{acc | longest: longest, longest_n: acc.longest_n + 1}
  end

  defp fold(%{"ph" => "i", "cat" => "build phase marker"} = e, acc) do
    ts = num(e["ts"])

    acc
    |> Map.update!(:markers, &[%{name: e["name"], ts: ts, dur: nil} | &1])
    |> Map.update!(:min_ts, &min_ts(&1, ts))
  end

  defp fold(%{"ph" => "C", "name" => name} = e, acc) do
    values = for {k, v} <- e["args"] || %{}, is_number(v), into: %{}, do: {k, v}

    Map.update!(acc, :counters, fn counters ->
      Map.update(counters, name, values, fn peaks ->
        Map.merge(peaks, values, fn _k, a, b -> max(a, b) end)
      end)
    end)
  end

  defp fold(_e, acc), do: acc

  defp add_total(map, key, dur) do
    Map.update(map, key, {dur, 1}, fn {d, n} -> {d + dur, n + 1} end)
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp min_ts(nil, ts), do: ts
  defp min_ts(a, ts), do: min(a, ts)

  defp top(list), do: list |> Enum.sort_by(& &1.dur, :desc) |> Enum.take(@top_n)

  defp finish(acc) do
    min_ts = acc.min_ts || 0
    duration_us = max(acc.max_end - min_ts, 0)
    markers = acc.markers |> Enum.reverse() |> Enum.sort_by(& &1.ts)

    phases =
      markers
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        dur =
          cond do
            m.dur -> m.dur
            i + 1 < length(markers) -> Enum.at(markers, i + 1).ts - m.ts
            true -> acc.max_end - m.ts
          end

        %{"name" => m.name, "start_ms" => ms(m.ts - min_ts), "duration_ms" => ms(dur)}
      end)

    critical = acc.critical |> Enum.sort_by(& &1.ts) |> Enum.take(200)

    %{
      "event_count" => acc.count,
      "duration_ms" => ms(duration_us),
      "thread_count" => map_size(acc.threads),
      "phases" => phases,
      "categories" => totals(acc.cats),
      "mnemonics" => totals(acc.mnemonics),
      "critical_path_ms" => ms(Enum.reduce(critical, 0, &(&1.dur + &2))),
      "critical_path" =>
        Enum.map(
          critical,
          &%{"name" => &1.name, "start_ms" => ms(&1.ts - min_ts), "duration_ms" => ms(&1.dur)}
        ),
      "longest" =>
        acc.longest
        |> top()
        |> Enum.map(fn e ->
          %{
            "name" => e.name,
            "category" => e.cat,
            "start_ms" => ms(e.ts - min_ts),
            "duration_ms" => ms(e.dur),
            "thread" => Map.get(acc.threads, e.thread, inspect(elem(e.thread, 1))),
            "target" => e.target,
            "mnemonic" => e.mnemonic
          }
        end),
      "counters" => acc.counters
    }
  end

  defp totals(map) do
    map
    |> Enum.map(fn {name, {dur, n}} -> %{"name" => name, "total_ms" => ms(dur), "count" => n} end)
    |> Enum.sort_by(& &1["total_ms"], :desc)
    |> Enum.take(@keep)
  end

  defp ms(us), do: Float.round(us / 1000, 1)
end
