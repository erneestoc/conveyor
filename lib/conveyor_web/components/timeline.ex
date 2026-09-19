defmodule ConveyorWeb.Timeline do
  @moduledoc """
  Tier A timeline: what Bazel reports through BEP alone, without a profile. Phases from
  the invocation's timing, one lane per test attempt and per reported action, drawn as an
  SVG so it works server-rendered and updates live. The profile-based timeline (Tier B)
  replaces the lanes when a `command.profile.gz` is available.
  """
  use Phoenix.Component
  use ConveyorWeb, :verified_routes

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

  attr :invocation, :map, required: true

  @doc "Tier B: the canvas profile timeline, driven by the ProfileTimeline hook."
  def profile_timeline(assigns) do
    ~H"""
    <div
      id="profile-timeline"
      phx-hook="ProfileTimeline"
      phx-update="ignore"
      data-url={~p"/invocation/#{@invocation.id}/download/profile"}
      data-worker={~p"/assets/js/profile_worker.js"}
      class="relative rounded-md border border-base-300 p-3 text-base-content"
    >
      <div class="mb-2 flex flex-wrap items-center gap-2 text-xs">
        <input
          type="search"
          data-role="search"
          placeholder="Search name, target, mnemonic…"
          class="w-64 rounded border border-base-300 bg-base-100 px-2 py-1 font-mono"
        />
        <select data-role="category" class="rounded border border-base-300 bg-base-100 px-2 py-1">
          <option value="-1">All categories</option>
        </select>
        <label class="flex items-center gap-1">
          <input type="checkbox" data-role="critical" /> Critical path only
        </label>
        <button
          type="button"
          data-role="reset"
          class="rounded border border-base-300 px-2 py-1 hover:bg-base-200"
        >
          Reset zoom
        </button>
        <span data-role="status" class="ml-auto text-base-content/60"></span>
      </div>
      <div data-role="scroller" class="max-h-[70vh] overflow-auto rounded bg-base-200/30">
        <canvas class="block cursor-crosshair"></canvas>
      </div>
      <div
        data-role="tooltip"
        hidden
        class="pointer-events-none absolute z-10 max-w-64 rounded border border-base-300 bg-base-100 px-2 py-1 font-mono text-[11px] shadow"
      >
      </div>
      <dl
        data-role="details"
        hidden
        class="mt-2 space-y-0.5 rounded border border-base-300 p-2 text-xs"
      >
      </dl>
      <p class="mt-2 text-[11px] text-base-content/50">
        Scroll to zoom, drag to pan, shift+scroll to slide, double-click to reset. Click an event for details.
      </p>
    </div>
    """
  end

  attr :summary, :map, required: true

  @doc "Where build time went, from the profile summary job."
  def profile_summary(assigns) do
    wall = max(assigns.summary["duration_ms"] || 0, 1)
    assigns = assign(assigns, wall: wall)

    ~H"""
    <div id="profile-summary" class="grid gap-3 text-xs lg:grid-cols-2">
      <div class="rounded-md border border-base-300 p-3">
        <h3 class="mb-1 text-sm font-semibold">Phases</h3>
        <div class="flex h-3 w-full overflow-hidden rounded bg-base-200" title="build phases">
          <div
            :for={{p, i} <- Enum.with_index(@summary["phases"] || [])}
            style={"width: #{Float.round(100 * p["duration_ms"] / @wall, 2)}%"}
            class={"h-full " <> Enum.at(~w(bg-sky-500 bg-emerald-500 bg-amber-500 bg-violet-500 bg-rose-500 bg-teal-500), rem(i, 6))}
            title={"#{p["name"]}: #{Format.duration(round(p["duration_ms"]))}"}
          >
          </div>
        </div>
        <ul class="mt-2 space-y-0.5">
          <li :for={p <- @summary["phases"] || []} class="flex justify-between font-mono">
            <span class="truncate">{p["name"]}</span>
            <span class="text-base-content/70">{Format.duration(round(p["duration_ms"]))}</span>
          </li>
        </ul>
        <p class="mt-2 text-base-content/60">
          {@summary["event_count"]} events on {@summary["thread_count"]} threads ·
          wall {Format.duration(round(@summary["duration_ms"] || 0))} ·
          critical path {Format.duration(round(@summary["critical_path_ms"] || 0))}
        </p>
      </div>
      <div class="rounded-md border border-base-300 p-3">
        <h3 class="mb-1 text-sm font-semibold">Time by category</h3>
        <table class="w-full">
          <tbody>
            <tr :for={c <- Enum.take(@summary["categories"] || [], 10)}>
              <td class="truncate py-0.5 pr-2 font-mono">{c["name"]}</td>
              <td class="py-0.5 pr-2 text-right font-mono text-base-content/70">{c["count"]}×</td>
              <td class="py-0.5 text-right font-mono">{Format.duration(round(c["total_ms"]))}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={(@summary["mnemonics"] || []) != []} class="rounded-md border border-base-300 p-3">
        <h3 class="mb-1 text-sm font-semibold">Action time by mnemonic</h3>
        <table class="w-full">
          <tbody>
            <tr :for={m <- Enum.take(@summary["mnemonics"] || [], 10)}>
              <td class="truncate py-0.5 pr-2 font-mono">{m["name"]}</td>
              <td class="py-0.5 pr-2 text-right font-mono text-base-content/70">{m["count"]}×</td>
              <td class="py-0.5 text-right font-mono">{Format.duration(round(m["total_ms"]))}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={(@summary["critical_path"] || []) != []} class="rounded-md border border-base-300 p-3">
        <h3 class="mb-1 text-sm font-semibold">Critical path</h3>
        <ol class="space-y-0.5">
          <li
            :for={c <- Enum.take(@summary["critical_path"] || [], 15)}
            class="flex justify-between gap-2 font-mono"
          >
            <span class="truncate">{c["name"]}</span>
            <span class="shrink-0 text-base-content/70">{Format.duration(round(c["duration_ms"]))}</span>
          </li>
        </ol>
      </div>
      <div class="rounded-md border border-base-300 p-3 lg:col-span-2">
        <h3 class="mb-1 text-sm font-semibold">Longest events</h3>
        <table class="w-full">
          <tbody>
            <tr :for={e <- Enum.take(@summary["longest"] || [], 15)}>
              <td class="max-w-md truncate py-0.5 pr-2 font-mono" title={e["target"] || e["name"]}>
                {e["name"]}
              </td>
              <td class="truncate py-0.5 pr-2 text-base-content/70">{e["category"]}</td>
              <td class="truncate py-0.5 pr-2 font-mono text-base-content/70">{e["thread"]}</td>
              <td class="py-0.5 text-right font-mono">{Format.duration(round(e["duration_ms"]))}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
