defmodule ConveyorWeb.DashboardLive do
  @moduledoc "Build health for a project (or all projects): outcomes, durations, cache, people, failures."
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents
  import ConveyorWeb.Charts

  alias Conveyor.Ingest
  alias Conveyor.Metrics.{Dashboard, Scope}
  alias Conveyor.Projects.Segments
  alias Conveyor.Query
  alias ConveyorWeb.Format

  @refresh_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    projects = ConveyorWeb.Auth.visible_projects(socket.assigns.current_scope)

    project =
      case params do
        %{"slug" => slug} ->
          ConveyorWeb.Auth.visible_project_by_slug(socket.assigns.current_scope, slug) ||
            raise ConveyorWeb.NotFoundError, "no project #{slug}"

        _ ->
          nil
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Conveyor.PubSub,
        if(project, do: Ingest.project_topic(project.id), else: Ingest.all_topic())
      )
    end

    {:ok,
     assign(socket,
       projects: projects,
       project: project,
       page_title: "Dashboard",
       refresh_timer: nil,
       q: "",
       query_error: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    range = if params["range"] in Scope.ranges(), do: params["range"], else: "7d"
    q = String.trim(params["q"] || "")
    segments = Segments.for_project(socket.assigns.project)
    names = Enum.map(segments, & &1["name"])

    {query, error} =
      case Query.parse(q) do
        {:ok, ast} -> {ast, nil}
        {:error, message} -> {[], "Could not understand the query: #{message}"}
      end

    segment = if params["segment"] in names, do: params["segment"], else: nil

    compare =
      case String.split(params["compare"] || "", ",") do
        [a, b] when a != b -> if a in names and b in names, do: [a, b], else: nil
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(
       range: range,
       q: q,
       query: query,
       query_error: error,
       segments: segments,
       segment: segment,
       compare: compare,
       current_path: URI.parse(uri).path
     )
     |> load()}
  end

  defp load(socket) do
    project = socket.assigns.project
    base = Scope.new(socket.assigns.range, project && project.id, socket.assigns.query)
    segments = socket.assigns.segments
    scope = if s = socket.assigns.segment, do: segment_scope(base, segments, s), else: base

    compare =
      socket.assigns.compare &&
        Enum.map(socket.assigns.compare, &{&1, load_scope(segment_scope(base, segments, &1))})

    assign(socket,
      scope: scope,
      main: load_scope(scope),
      comparison: compare,
      segment_summaries:
        base
        |> Scope.segments(segments)
        |> Enum.map(&{&1.name, Dashboard.summary(&1)}),
      bucket: Scope.bucket(scope)
    )
  end

  defp segment_scope(base, segments, name) do
    base |> Scope.segments(Enum.filter(segments, &(&1["name"] == name))) |> hd()
  end

  # Everything one column of the dashboard shows for one scope.
  defp load_scope(scope) do
    summary = Dashboard.summary(scope)
    previous = Dashboard.summary(Scope.previous(scope))

    %{
      summary: summary,
      previous: previous,
      deltas: Dashboard.deltas(summary, previous),
      series: Dashboard.series(scope),
      failures: Dashboard.failure_breakdown(scope),
      strategy: Dashboard.strategy_mix(scope),
      by_user: Dashboard.by_user(scope, 8),
      slowest: Dashboard.slowest_builds(scope, 8),
      versions: Dashboard.versions(scope),
      failing_targets: Dashboard.top_failing_targets(scope, 8),
      by_hour: Dashboard.builds_by_hour(scope)
    }
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, range: range))}

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, q: String.trim(q)))}

  def handle_event("segment", %{"name" => name}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, segment: name, compare: nil))}

  def handle_event("compare", %{"a" => a, "b" => b}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, compare: "#{a},#{b}", segment: nil))}

  def handle_event("compare_off", _params, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, compare: nil))}

  # Finished builds change the numbers; refresh at most every few seconds.
  @impl true
  def handle_info(
        {:invocation_updated, %{finalized: true}},
        %{assigns: %{refresh_timer: nil}} = socket
      ) do
    {:noreply, assign(socket, refresh_timer: Process.send_after(self(), :refresh, @refresh_ms))}
  end

  def handle_info({:invocation_updated, _}, socket), do: {:noreply, socket}

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_timer: nil) |> load()}

  defp page_path(socket, changes) do
    base =
      if socket.assigns.project,
        do: ~p"/p/#{socket.assigns.project.slug}/dashboard",
        else: ~p"/dashboard"

    current = [
      range: socket.assigns.range,
      q: socket.assigns.q,
      segment: socket.assigns.segment,
      compare: socket.assigns.compare && Enum.join(socket.assigns.compare, ",")
    ]

    params =
      current
      |> Keyword.merge(changes)
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    base <> "?" <> URI.encode_query(params)
  end

  defp slug(name), do: String.replace(name, ~r/[^a-zA-Z0-9]+/, "-")

  defp pct(nil), do: "—"
  defp pct(f), do: "#{round(f * 100)}%"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      projects={@projects}
      project={@project}
      current_path={@current_path}
    >
      <div class="flex flex-wrap items-center justify-between gap-3 pb-3">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">Dashboard</h1>
          <p class="text-xs text-base-content/60">
            {if @project, do: @project.name, else: "All projects"} · last {@range} · {Format.number(
              @main.summary.builds
            )} builds
          </p>
        </div>
        <form
          phx-submit="search"
          class="flex min-w-0 flex-1 items-center gap-2 sm:max-w-md"
          id="dashboard-search"
        >
          <input
            type="search"
            name="q"
            id="dashboard-q"
            value={@q}
            placeholder="filter, e.g. team:infra branch:main"
            autocomplete="off"
            class="w-full rounded-md border border-base-300 bg-base-100 px-2 py-1.5 font-mono text-xs placeholder:text-base-content/40 focus:border-primary focus:outline-none"
          />
          <button
            type="submit"
            class="rounded-md bg-base-content px-3 py-1.5 text-xs font-medium text-base-100"
          >Apply</button>
        </form>
        <div
          class="flex items-center gap-1 rounded-md border border-base-300 p-0.5 text-xs"
          id="range-picker"
        >
          <button
            :for={r <- Scope.ranges()}
            type="button"
            id={"range-#{r}"}
            phx-click="range"
            phx-value-range={r}
            aria-selected={to_string(@range == r)}
            class={[
              "rounded px-2.5 py-1",
              @range == r && "bg-base-content text-base-100",
              @range != r && "text-base-content/70 hover:bg-base-200"
            ]}
          >{r}</button>
        </div>
      </div>
      <p
        :if={@query_error}
        id="query-error"
        class="mb-3 rounded-md border border-rose-500/30 bg-rose-500/5 px-3 py-2 text-xs text-rose-700 dark:text-rose-300"
      >
        {@query_error}
      </p>

      <div class="mb-3 flex flex-wrap items-center gap-2 text-xs" id="segment-chips">
        <span class="text-base-content/50">Segment</span>
        <button
          type="button"
          id="segment-chip-all"
          phx-click="segment"
          phx-value-name=""
          aria-selected={to_string(is_nil(@segment) and is_nil(@compare))}
          class={chip_class(is_nil(@segment) and is_nil(@compare))}
        >All</button>
        <button
          :for={seg <- @segments}
          type="button"
          id={"segment-chip-#{slug(seg["name"])}"}
          phx-click="segment"
          phx-value-name={seg["name"]}
          title={seg["query"]}
          aria-selected={to_string(@segment == seg["name"])}
          class={chip_class(@segment == seg["name"])}
        >{seg["name"]}</button>
        <form
          :if={length(@segments) >= 2}
          id="compare-form"
          phx-submit="compare"
          class="ml-2 flex items-center gap-1"
        >
          <span class="text-base-content/50">Compare</span>
          <select name="a" class="rounded border border-base-300 bg-base-100 px-1 py-0.5">
            <option
              :for={seg <- @segments}
              value={seg["name"]}
              selected={@compare && hd(@compare) == seg["name"]}
            >
              {seg["name"]}
            </option>
          </select>
          <span class="text-base-content/50">vs</span>
          <select name="b" class="rounded border border-base-300 bg-base-100 px-1 py-0.5">
            <option
              :for={seg <- @segments}
              value={seg["name"]}
              selected={
                if(@compare,
                  do: List.last(@compare) == seg["name"],
                  else: seg == Enum.at(@segments, 1)
                )
              }
            >
              {seg["name"]}
            </option>
          </select>
          <button type="submit" class="rounded border border-base-300 px-2 py-0.5 hover:bg-base-200">
            Go
          </button>
          <button
            :if={@compare}
            type="button"
            id="compare-off"
            phx-click="compare_off"
            class="text-base-content/60 hover:underline"
          >close</button>
        </form>
        <.link
          :if={@project && @current_scope && @current_scope.admin?}
          navigate={~p"/settings"}
          class="ml-auto text-base-content/60 hover:underline"
        >manage segments</.link>
      </div>

      <div :if={@comparison} id="compare" class="grid gap-4 lg:grid-cols-2">
        <section :for={{name, data} <- @comparison} id={"compare-#{slug(name)}"}>
          <h2 class="mb-2 text-sm font-semibold">{name}</h2>
          <.tiles data={data} sfx={"-#{slug(name)}"} class="grid-cols-2 sm:grid-cols-3" />
          <.panels data={data} sfx={"-#{slug(name)}"} class="mt-4 grid gap-4" />
        </section>
      </div>

      <div :if={is_nil(@comparison)}>
        <.tiles data={@main} sfx="" class="grid-cols-2 sm:grid-cols-3 lg:grid-cols-6" />

        <div class="mt-4 overflow-x-auto rounded-md border border-base-300" id="segments">
          <table class="w-full text-sm">
            <thead class="bg-base-200/60 text-left text-[11px] uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2 font-medium">Segment</th><th class="px-3 py-2 text-right font-medium">
                  Builds
                </th><th class="px-3 py-2 text-right font-medium">Success</th><th class="px-3 py-2 text-right font-medium">
                  p50
                </th><th class="px-3 py-2 text-right font-medium">p90</th><th class="px-3 py-2 text-right font-medium">
                  p99
                </th><th class="px-3 py-2 text-right font-medium">Cache hits</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
              <tr :for={{name, s} <- @segment_summaries} id={"segment-#{name}"}>
                <td class="px-3 py-1.5 font-sans font-medium">{name}</td>
                <td class="px-3 py-1.5 text-right">{Format.number(s.builds)}</td>
                <td class={["px-3 py-1.5 text-right", tone_text(tone(s.success_rate))]}>
                  {pct(s.success_rate)}
                </td>
                <td class="px-3 py-1.5 text-right">{Format.duration(s.p50)}</td>
                <td class="px-3 py-1.5 text-right">{Format.duration(s.p90)}</td>
                <td class="px-3 py-1.5 text-right">{Format.duration(s.p99)}</td>
                <td class="px-3 py-1.5 text-right">{pct(s.cache_hit_rate)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <.panels data={@main} sfx="" class="mt-4 grid gap-4 lg:grid-cols-2" />
      </div>
    </Layouts.app>
    """
  end

  attr :data, :map, required: true
  attr :sfx, :string, required: true
  attr :class, :string, required: true

  defp tiles(assigns) do
    ~H"""
    <div class={["grid gap-3", @class]} id={"headline#{@sfx}"}>
      <.tile
        id={"tile-builds#{@sfx}"}
        label="Builds"
        value={Format.number(@data.summary.builds)}
        sub={"#{@data.summary.running} running"}
        delta={@data.deltas.builds}
        previous={Format.number(@data.previous.builds)}
        up={:neutral}
      />
      <.tile
        id={"tile-success#{@sfx}"}
        label="Success rate"
        value={pct(@data.summary.success_rate)}
        sub={"#{@data.summary.failed} failed · #{@data.summary.aborted} aborted"}
        tone={tone(@data.summary.success_rate)}
        delta={@data.deltas.success_rate}
        previous={pct(@data.previous.success_rate)}
        up={:good}
      />
      <.tile
        id={"tile-p50#{@sfx}"}
        label="p50 duration"
        value={Format.duration(@data.summary.p50)}
        sub="finished builds"
        delta={@data.deltas.p50}
        previous={Format.duration(@data.previous.p50)}
        up={:bad}
      />
      <.tile
        id={"tile-p90#{@sfx}"}
        label="p90 duration"
        value={Format.duration(@data.summary.p90)}
        sub="finished builds"
        delta={@data.deltas.p90}
        previous={Format.duration(@data.previous.p90)}
        up={:bad}
      />
      <.tile
        id={"tile-p99#{@sfx}"}
        label="p99 duration"
        value={Format.duration(@data.summary.p99)}
        sub="finished builds"
        delta={@data.deltas.p99}
        previous={Format.duration(@data.previous.p99)}
        up={:bad}
      />
      <.tile
        id={"tile-cache#{@sfx}"}
        label="Cache hit rate"
        value={pct(@data.summary.cache_hit_rate)}
        sub={"#{@data.summary.users} users"}
        delta={@data.deltas.cache_hit_rate}
        previous={pct(@data.previous.cache_hit_rate)}
        up={:good}
      />
    </div>
    """
  end

  attr :data, :map, required: true
  attr :sfx, :string, required: true
  attr :class, :string, required: true

  defp panels(assigns) do
    ~H"""
    <div class={@class}>
      <.panel title="Builds over time" id={"panel-builds#{@sfx}"}>
        <.stacked_bars
          id={"chart-builds#{@sfx}"}
          points={@data.series}
          series={[
            {:succeeded, "text-emerald-500"},
            {:failed, "text-rose-500"},
            {:other, "text-zinc-400"}
          ]}
        />
        <.legend items={[
          {"succeeded", "text-emerald-500"},
          {"failed", "text-rose-500"},
          {"other", "text-zinc-400"}
        ]} />
      </.panel>
      <.panel title="Duration percentiles" id={"panel-durations#{@sfx}"}>
        <.lines
          id={"chart-durations#{@sfx}"}
          points={@data.series}
          series={[
            {:p50, "text-sky-500", "p50"},
            {:p90, "text-amber-500", "p90"},
            {:p99, "text-rose-500", "p99"}
          ]}
        />
        <.legend items={[
          {"p50", "text-sky-500"},
          {"p90", "text-amber-500"},
          {"p99", "text-rose-500"}
        ]} />
      </.panel>
      <.panel title="Remote cache hit rate" id={"panel-cache#{@sfx}"}>
        <.lines
          id={"chart-cache#{@sfx}"}
          points={
            Enum.map(
              @data.series,
              &%{&1 | cache_hit_rate: &1.cache_hit_rate && &1.cache_hit_rate * 100}
            )
          }
          series={[{:cache_hit_rate, "text-primary", "cache hit rate"}]}
          label_fun={&"#{round(&1)}%"}
          max={100}
        />
      </.panel>
      <.panel title="Execution strategy" id={"panel-strategy#{@sfx}"}>
        <.hbars id={"chart-strategy#{@sfx}"} items={@data.strategy} />
      </.panel>
      <.panel title="Failures by exit code" id={"panel-failures#{@sfx}"}>
        <.hbars id={"chart-failures#{@sfx}"} items={@data.failures} class="text-rose-500" />
      </.panel>
      <.panel title="Most failing targets" id={"panel-targets#{@sfx}"}>
        <.hbars
          id={"chart-targets#{@sfx}"}
          items={Enum.map(@data.failing_targets, &{&1.label, &1.failures})}
          class="text-rose-500"
        />
      </.panel>
      <.panel title="Builds per user" id={"panel-users#{@sfx}"}>
        <table class="w-full text-xs">
          <tbody class="divide-y divide-base-300/60">
            <tr :for={u <- @data.by_user}>
              <td class="py-1 font-mono">{u.user}</td><td class="py-1 text-right tabular-nums">
                {Format.number(u.builds)}
              </td><td class="py-1 text-right tabular-nums text-rose-600 dark:text-rose-400">
                {if u.failed > 0, do: "#{u.failed} failed"}
              </td><td class="py-1 text-right font-mono tabular-nums">{Format.duration(u.p50)}</td>
            </tr>
            <tr :if={@data.by_user == []}>
              <td class="py-1 text-base-content/50">nothing in this window</td>
            </tr>
          </tbody>
        </table>
      </.panel>
      <.panel title="Slowest builds" id={"panel-slowest#{@sfx}"}>
        <table class="w-full text-xs">
          <tbody class="divide-y divide-base-300/60">
            <tr :for={inv <- @data.slowest}>
              <td class="py-1">
                <.status_pill status={inv.status} exit_code_name={inv.exit_code_name} size="xs" />
              </td>
              <td class="max-w-xs truncate py-1 font-mono">
                <.link navigate={~p"/invocation/#{inv.id}"} class="hover:underline">{Format.command_line(
                  inv
                )}</.link>
              </td>
              <td class="py-1 text-base-content/60">{inv.user_name}</td>
              <td class="py-1 text-right font-mono tabular-nums">
                {Format.duration(inv.duration_ms)}
              </td>
            </tr>
            <tr :if={@data.slowest == []}>
              <td class="py-1 text-base-content/50">nothing in this window</td>
            </tr>
          </tbody>
        </table>
      </.panel>
      <.panel title="Builds by hour (UTC)" id={"panel-hours#{@sfx}"}>
        <.stacked_bars
          id={"chart-hours#{@sfx}"}
          points={Enum.map(@data.by_hour, fn {h, n} -> %{bucket: "#{h}h", builds: n} end)}
          series={[{:builds, "text-primary"}]}
        />
      </.panel>
      <.panel title="Bazel versions" id={"panel-versions#{@sfx}"}>
        <.hbars id={"chart-versions#{@sfx}"} items={@data.versions} />
      </.panel>
    </div>
    """
  end

  defp chip_class(selected?) do
    [
      "rounded-full border px-2.5 py-0.5",
      selected? && "border-base-content bg-base-content text-base-100",
      !selected? && "border-base-300 text-base-content/70 hover:bg-base-200"
    ]
  end

  attr :title, :string, required: true
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section id={@id} class="rounded-md border border-base-300 p-4">
      <h2 class="mb-3 text-sm font-semibold">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :tone, :atom, default: :neutral
  attr :delta, :float, default: nil
  attr :previous, :string, default: nil
  # Whether an increase is good, bad or neither: colours the delta.
  attr :up, :atom, default: :neutral

  defp tile(assigns) do
    ~H"""
    <div class="rounded-md border border-base-300 px-3 py-2" id={@id}>
      <div class="text-[11px] uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class={["text-xl font-semibold tabular-nums", tone_text(@tone)]}>{@value}</div>
      <div class="flex items-baseline justify-between gap-2 text-[11px] text-base-content/50">
        <span :if={@sub}>{@sub}</span>
        <span
          :if={@delta}
          class={["ml-auto font-mono tabular-nums", delta_text(@delta, @up)]}
          title={"previous period: #{@previous}"}
          data-delta={@delta}
        >{delta_label(@delta)}</span>
      </div>
    </div>
    """
  end

  defp delta_label(d) when d > 0, do: "▲ #{round(d * 100)}%"
  defp delta_label(d) when d < 0, do: "▼ #{round(-d * 100)}%"
  defp delta_label(_), do: "= 0%"

  defp delta_text(d, up) when d == 0 or up == :neutral, do: nil
  defp delta_text(d, :good) when d > 0, do: tone_text(:good)
  defp delta_text(_d, :good), do: tone_text(:bad)
  defp delta_text(d, :bad) when d > 0, do: tone_text(:bad)
  defp delta_text(_d, :bad), do: tone_text(:good)

  defp tone(nil), do: :neutral
  defp tone(rate) when rate >= 0.9, do: :good
  defp tone(rate) when rate >= 0.7, do: :warn
  defp tone(_), do: :bad

  defp tone_text(:good), do: "text-emerald-600 dark:text-emerald-400"
  defp tone_text(:warn), do: "text-amber-600 dark:text-amber-400"
  defp tone_text(:bad), do: "text-rose-600 dark:text-rose-400"
  defp tone_text(_), do: nil
end
