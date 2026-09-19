defmodule ConveyorWeb.Timeline do
  @moduledoc """
  Tier A timeline: what Bazel reports through BEP alone, without a profile. Phases from
  the invocation's timing, one lane per test attempt and per reported action, drawn as an
  SVG so it works server-rendered and updates live. The profile-based timeline (Tier B)
  replaces the lanes when a `command.profile.gz` is available.
  """
  use Phoenix.Component

  alias ConveyorWeb.Format

  @row_h 16
  @label_w 260
  @width 1000
  @max_rows 400

  @doc "Builds drawable rows from an invocation, its test attempts and actions."
  @spec rows(map(), [map()], [map()], DateTime.t()) :: %{
          rows: [map()],
          start: DateTime.t() | nil,
          span_ms: integer(),
          truncated: integer()
        }
  def rows(inv, tests, actions, now \\ DateTime.utc_now()) do
    start = inv.started_at
    finish = inv.finished_at || now

    if is_nil(start) do
      %{rows: [], start: nil, span_ms: 0, truncated: 0}
    else
      span = max(DateTime.diff(finish, start, :millisecond), 1)

      phases =
        [
          inv.analysis_ms &&
            %{
              kind: :phase,
              label: "analysis",
              start_ms: 0,
              dur_ms: inv.analysis_ms,
              class: "fill-sky-500/70"
            },
          inv.execution_ms &&
            %{
              kind: :phase,
              label: "execution",
              start_ms: inv.analysis_ms || 0,
              dur_ms: inv.execution_ms,
              class: "fill-emerald-500/60"
            }
        ]
        |> Enum.reject(&is_nil/1)

      tests =
        for t <- tests, t.started_at != nil do
          %{
            kind: :test,
            label:
              "#{t.label}#{if t.shard > 1 or t.attempt > 1, do: " s#{t.shard}/a#{t.attempt}", else: ""}",
            start_ms: DateTime.diff(t.started_at, start, :millisecond),
            dur_ms: t.duration_ms || 0,
            class: if(t.status == "PASSED", do: "fill-emerald-500", else: "fill-rose-500"),
            title: "#{t.status} · #{Format.duration(t.duration_ms)}"
          }
        end

      actions =
        for a <- actions, a.started_at != nil do
          %{
            kind: :action,
            label: "#{a.mnemonic || "action"} #{a.label || a.primary_output || ""}",
            start_ms: DateTime.diff(a.started_at, start, :millisecond),
            dur_ms: a.duration_ms || 0,
            class: if(a.success, do: "fill-primary", else: "fill-rose-500"),
            title:
              "#{if a.success, do: "ok", else: "exit #{a.exit_code}"} · #{Format.duration(a.duration_ms)}"
          }
        end

      lanes = Enum.sort_by(tests ++ actions, & &1.start_ms)

      %{
        rows: phases ++ Enum.take(lanes, @max_rows),
        start: start,
        span_ms: span,
        truncated: max(length(lanes) - @max_rows, 0)
      }
    end
  end

  attr :invocation, :map, required: true
  attr :tests, :list, required: true
  attr :actions, :list, required: true

  def timeline(assigns) do
    data = rows(assigns.invocation, assigns.tests, assigns.actions)
    plot_w = @width - @label_w
    height = length(data.rows) * @row_h + 24
    ticks = for i <- 0..4, do: {i / 4, round(data.span_ms * i / 4)}

    assigns =
      assign(assigns,
        data: data,
        plot_w: plot_w,
        height: height,
        ticks: ticks,
        width: @width,
        label_w: @label_w,
        row_h: @row_h
      )

    ~H"""
    <div id="timeline" class="rounded-md border border-base-300 p-3">
      <p :if={@data.rows == []} class="py-8 text-center text-sm text-base-content/60">
        Nothing to draw yet: the timeline fills in as tests and actions report their timing.
      </p>
      <div :if={@data.rows != []} class="overflow-x-auto">
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          class="w-full min-w-[720px]"
          style={"height: #{@height}px"}
          role="img"
          font-size="10"
        >
          <g :for={{frac, ms} <- @ticks} class="text-base-content/40">
            <line
              x1={@label_w + frac * @plot_w}
              x2={@label_w + frac * @plot_w}
              y1="0"
              y2={@height - 14}
              stroke="currentColor"
              stroke-opacity="0.25"
            />
            <text
              x={@label_w + frac * @plot_w}
              y={@height - 3}
              text-anchor={if(frac == 1.0, do: "end", else: "middle")}
              fill="currentColor"
            >
              {Format.duration(ms)}
            </text>
          </g>
          <g :for={{row, i} <- Enum.with_index(@data.rows)} data-kind={row.kind}>
            <text
              x={@label_w - 6}
              y={i * @row_h + 12}
              text-anchor="end"
              class="fill-current font-mono text-base-content/80"
            >
              {Format.truncate(row.label, 42)}
            </text>
            <rect
              x={@label_w + max(row.start_ms, 0) / @data.span_ms * @plot_w}
              y={i * @row_h + 3}
              width={max(row.dur_ms / @data.span_ms * @plot_w, 2)}
              height={@row_h - 6}
              rx="2"
              class={row.class}
            >
              <title>{row.label} · {Map.get(row, :title, Format.duration(row.dur_ms))}</title>
            </rect>
          </g>
        </svg>
      </div>
      <p class="mt-2 text-[11px] text-base-content/50">
        Phases from Bazel's timing metrics, tests from their attempt timings, actions as reported (all actions with <code class="font-mono">--build_event_publish_all_actions</code>).
        <span :if={@data.truncated > 0}>{@data.truncated} more rows not shown.</span>
        The full per-action profile timeline arrives once the build's
        <code class="font-mono">command.profile.gz</code>
        can be fetched.
      </p>
    </div>
    """
  end
end
