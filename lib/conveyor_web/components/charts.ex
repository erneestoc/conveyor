defmodule ConveyorWeb.Charts do
  @moduledoc """
  Small, dependency-free SVG charts for the dashboard: stacked bars, multi-series lines
  and horizontal bar lists. Colours come from theme tokens via CSS classes so both themes
  work; numbers are formatted by the caller.
  """
  use Phoenix.Component

  alias ConveyorWeb.Format

  @width 600
  @height 160
  @pad_left 44
  @pad_bottom 22
  @pad_top 8

  # Action phases in stacking order, with the palette shared by the timeline and the
  # dashboard. Colours are hex so they can be used as SVG fills and inline backgrounds.
  @phases [
    {"cache check", "#0ea5e9"},
    {"upload inputs", "#f59e0b"},
    {"queued", "#a3a3a3"},
    {"remote execution", "#8b5cf6"},
    {"download outputs", "#14b8a6"},
    {"local execution", "#10b981"},
    {"setup", "#f97316"},
    {"outputs", "#64748b"}
  ]

  @doc "Action phases as `{name, colour}` in stacking order."
  @spec phases() :: [{String.t(), String.t()}]
  def phases, do: @phases

  @doc "The colour of an action phase (grey for unknown names)."
  @spec phase_color(String.t()) :: String.t()
  def phase_color(name), do: List.keyfind(@phases, name, 0, {name, "#94a3b8"}) |> elem(1)

  @doc """
  Stacked bars per bucket; `series` is a list of `{key, class_or_colour}` in stacking order.
  A colour (`#rrggbb`) is used as the fill directly; anything else is a text colour class.
  """
  attr :points, :list, required: true, doc: "maps with :bucket and one integer per series key"
  attr :series, :list, required: true
  attr :id, :string, required: true
  attr :label_fun, :any, default: &Format.number/1

  def stacked_bars(assigns) do
    points = assigns.points

    totals =
      Enum.map(points, fn p ->
        assigns.series |> Enum.map(fn {k, _} -> Map.get(p, k, 0) end) |> Enum.sum()
      end)

    max = max(Enum.max(totals, fn -> 0 end), 1)
    n = max(length(points), 1)
    slot = (@width - @pad_left) / n
    bar_w = max(slot * 0.7, 1)
    plot_h = @height - @pad_bottom - @pad_top

    bars =
      points
      |> Enum.with_index()
      |> Enum.flat_map(fn {p, i} ->
        x = @pad_left + i * slot + (slot - bar_w) / 2

        assigns.series
        |> Enum.reduce({[], 0}, fn {key, class}, {acc, stacked} ->
          v = Map.get(p, key, 0)
          h = v / max * plot_h
          y = @pad_top + plot_h - stacked / max * plot_h - h

          {[
             %{
               x: x,
               y: y,
               w: bar_w,
               h: h,
               class: class,
               title: "#{key}: #{assigns.label_fun.(v)}"
             }
             | acc
           ], stacked + v}
        end)
        |> elem(0)
      end)

    assigns =
      assign(assigns,
        bars: bars,
        max: max,
        ticks: ticks(max),
        plot_h: plot_h,
        labels: x_labels(points),
        width: @width,
        height: @height,
        pad_left: @pad_left,
        pad_top: @pad_top
      )

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 #{@width} #{@height}"}
      class="h-40 w-full"
      role="img"
      preserveAspectRatio="none"
    >
      <g :for={t <- @ticks} class="text-base-content/40">
        <line
          x1={@pad_left}
          x2={@width}
          y1={@pad_top + @plot_h - t / @max * @plot_h}
          y2={@pad_top + @plot_h - t / @max * @plot_h}
          stroke="currentColor"
          stroke-opacity="0.25"
          stroke-width="1"
        />
        <text
          x={@pad_left - 6}
          y={@pad_top + @plot_h - t / @max * @plot_h + 3}
          text-anchor="end"
          font-size="9"
          fill="currentColor"
        >
          {@label_fun.(t)}
        </text>
      </g>
      <rect
        :for={b <- @bars}
        x={b.x}
        y={b.y}
        width={b.w}
        height={b.h}
        class={if(colour?(b.class), do: nil, else: b.class)}
        fill={if(colour?(b.class), do: b.class, else: "currentColor")}
      >
        <title>{b.title}</title>
      </rect>
      <text
        :for={{label, x} <- @labels}
        x={@pad_left + x}
        y={@height - 6}
        text-anchor="middle"
        font-size="9"
        class="text-base-content/50"
        fill="currentColor"
      >
        {label}
      </text>
    </svg>
    """
  end

  @doc "Multi-series line chart; `series` is a list of `{key, class, label}`; nil values break the line."
  attr :points, :list, required: true
  attr :series, :list, required: true
  attr :id, :string, required: true
  attr :label_fun, :any, default: &Format.duration/1
  attr :max, :any, default: nil

  def lines(assigns) do
    points = assigns.points
    values = for p <- points, {k, _, _} <- assigns.series, v = Map.get(p, k), v != nil, do: v
    max = max(assigns.max || Enum.max(values, fn -> 1 end), 1)
    n = max(length(points) - 1, 1)
    plot_w = @width - @pad_left
    plot_h = @height - @pad_bottom - @pad_top

    paths =
      Enum.map(assigns.series, fn {key, class, label} ->
        d =
          points
          |> Enum.with_index()
          |> Enum.chunk_by(fn {p, _} -> Map.get(p, key) == nil end)
          |> Enum.reject(fn [{p, _} | _] -> Map.get(p, key) == nil end)
          |> Enum.map_join(" ", fn segment ->
            segment
            |> Enum.with_index()
            |> Enum.map_join(" ", fn {{p, i}, j} ->
              x = @pad_left + i / n * plot_w
              y = @pad_top + plot_h - min(Map.get(p, key) / max, 1) * plot_h
              "#{if j == 0, do: "M", else: "L"}#{fmt(x)} #{fmt(y)}"
            end)
          end)

        # Hover targets carrying the exact value of every point.
        dots =
          points
          |> Enum.with_index()
          |> Enum.reject(fn {p, _} -> Map.get(p, key) == nil end)
          |> Enum.map(fn {p, i} ->
            %{
              x: @pad_left + i / n * plot_w,
              y: @pad_top + plot_h - min(Map.get(p, key) / max, 1) * plot_h,
              class: class,
              title:
                "#{label} · #{Map.get(p, :label) || Map.get(p, :day) || i + 1} · #{assigns.label_fun.(Map.get(p, key))}"
            }
          end)

        %{d: d, class: class, label: label, dots: dots}
      end)

    assigns =
      assign(assigns,
        paths: paths,
        max: max,
        ticks: ticks(max),
        plot_h: plot_h,
        labels: x_labels(points),
        width: @width,
        height: @height,
        pad_left: @pad_left,
        pad_top: @pad_top
      )

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 #{@width} #{@height}"}
      class="h-40 w-full"
      role="img"
      preserveAspectRatio="none"
    >
      <g :for={t <- @ticks} class="text-base-content/40">
        <line
          x1={@pad_left}
          x2={@width}
          y1={@pad_top + @plot_h - t / @max * @plot_h}
          y2={@pad_top + @plot_h - t / @max * @plot_h}
          stroke="currentColor"
          stroke-opacity="0.25"
          stroke-width="1"
        />
        <text
          x={@pad_left - 6}
          y={@pad_top + @plot_h - t / @max * @plot_h + 3}
          text-anchor="end"
          font-size="9"
          fill="currentColor"
        >
          {@label_fun.(t)}
        </text>
      </g>
      <path
        :for={p <- @paths}
        d={p.d}
        class={p.class}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
      >
        <title>{p.label}</title>
      </path>
      <circle
        :for={dot <- Enum.flat_map(@paths, & &1.dots)}
        cx={dot.x}
        cy={dot.y}
        r="4"
        fill="transparent"
        pointer-events="all"
        class={dot.class}
      >
        <title>{dot.title}</title>
      </circle>
      <circle
        :for={dot <- Enum.flat_map(@paths, & &1.dots)}
        cx={dot.x}
        cy={dot.y}
        r="4"
        fill="transparent"
        pointer-events="all"
        class={dot.class}
      >
        <title>{dot.title}</title>
      </circle>
      <text
        :for={{label, x} <- @labels}
        x={@pad_left + x}
        y={@height - 6}
        text-anchor="middle"
        font-size="9"
        class="text-base-content/50"
        fill="currentColor"
      >
        {label}
      </text>
    </svg>
    """
  end

  @doc "Horizontal bars for a breakdown list of `{label, value}`."
  attr :items, :list, required: true
  attr :id, :string, required: true
  attr :class, :string, default: "text-primary"
  attr :label_fun, :any, default: &Format.number/1

  def hbars(assigns) do
    max = assigns.items |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, max: max)

    ~H"""
    <ul id={@id} class="space-y-1.5 text-xs">
      <li
        :for={{label, value} <- @items}
        class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2"
      >
        <div class="min-w-0">
          <div class="truncate font-mono" title={to_string(label)}>{label}</div>
          <div class="mt-0.5 h-1.5 rounded bg-base-300">
            <div
              class={["h-1.5 rounded bg-current", @class]}
              style={"width: #{round(value / @max * 100)}%"}
            >
            </div>
          </div>
        </div>
        <span class="tabular-nums text-base-content/70">{@label_fun.(value)}</span>
      </li>
      <li :if={@items == []} class="text-base-content/50">nothing in this window</li>
    </ul>
    """
  end

  @doc "A legend for series classes or colours."
  attr :items, :list, required: true, doc: "list of {label, class_or_colour}"

  def legend(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-3 text-[11px] text-base-content/60">
      <span :for={{label, class} <- @items} class="inline-flex items-center gap-1"><span
        class={["inline-block size-2 rounded-sm", !colour?(class) && "bg-current", class]}
        style={colour?(class) && "background: #{class}"}
      ></span>{label}</span>
    </div>
    """
  end

  defp colour?("#" <> _), do: true
  defp colour?(_), do: false

  # --- helpers -----------------------------------------------------------------------------

  defp ticks(max) do
    step = nice_step(max / 3)
    Stream.iterate(0, &(&1 + step)) |> Enum.take_while(&(&1 <= max)) |> Enum.take(6)
  end

  defp nice_step(raw) when raw <= 0, do: 1

  defp nice_step(raw) do
    mag = :math.pow(10, Float.floor(:math.log10(raw)))
    norm = raw / mag

    mult =
      cond do
        norm <= 1 -> 1
        norm <= 2 -> 2
        norm <= 5 -> 5
        true -> 10
      end

    round(mult * mag) |> max(1)
  end

  # At most ~8 x labels, evenly spaced.
  defp x_labels(points) do
    n = length(points)

    if n == 0 do
      []
    else
      every = max(div(n, 8), 1)
      plot_w = @width - @pad_left

      points
      |> Enum.with_index()
      |> Enum.filter(fn {_, i} -> rem(i, every) == 0 end)
      |> Enum.map(fn {p, i} ->
        {bucket_label(p.bucket), if(n == 1, do: plot_w / 2, else: i / max(n - 1, 1) * plot_w)}
      end)
    end
  end

  defp bucket_label(%DateTime{hour: 0, minute: 0} = dt), do: Calendar.strftime(dt, "%b %d")
  defp bucket_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp bucket_label(other), do: to_string(other)

  defp fmt(f), do: :erlang.float_to_binary(f * 1.0, decimals: 1)
end
