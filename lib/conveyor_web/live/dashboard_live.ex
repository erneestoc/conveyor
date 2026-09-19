defmodule ConveyorWeb.DashboardLive do
  @moduledoc "Build health for a project (or all projects): outcomes, durations, cache, people, failures."
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents
  import ConveyorWeb.Charts

  alias Conveyor.Ingest
  alias Conveyor.Metrics.{Dashboard, Scope}
  alias Conveyor.Projects
  alias Conveyor.Projects.Segments
  alias Conveyor.Query
  alias ConveyorWeb.Format

  @refresh_ms 5_000

  @impl true
  def mount(params, _session, socket) do
    projects = Projects.list_projects()

    project =
      case params do
        %{"slug" => slug} ->
          Projects.get_project_by_slug(slug) ||
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

    {query, error} =
      case Query.parse(q) do
        {:ok, ast} -> {ast, nil}
        {:error, message} -> {[], "Could not understand the query: #{message}"}
      end

    {:noreply,
     socket
     |> assign(
       range: range,
       q: q,
       query: query,
       query_error: error,
       current_path: URI.parse(uri).path
     )
     |> load()}
  end

  defp load(socket) do
    project = socket.assigns.project
    scope = Scope.new(socket.assigns.range, project && project.id, socket.assigns.query)
    segments = Scope.segments(scope, Segments.for_project(project))

    assign(socket,
      scope: scope,
      summary: Dashboard.summary(scope),
      segment_summaries: Enum.map(segments, &{&1.name, Dashboard.summary(&1)}),
      series: Dashboard.series(scope),
      segment_series: Enum.map(segments, &{&1.name, Dashboard.series(&1)}),
      failures: Dashboard.failure_breakdown(scope),
      strategy: Dashboard.strategy_mix(scope),
      by_user: Dashboard.by_user(scope, 8),
      slowest: Dashboard.slowest_builds(scope, 8),
      versions: Dashboard.versions(scope),
      failing_targets: Dashboard.top_failing_targets(scope, 8),
      by_hour: Dashboard.builds_by_hour(scope),
      bucket: Scope.bucket(scope)
    )
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, range, socket.assigns.q))}

  def handle_event("search", %{"q" => q}, socket),
    do:
      {:noreply, push_patch(socket, to: page_path(socket, socket.assigns.range, String.trim(q)))}

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

  defp page_path(socket, range, q) do
    base =
      if socket.assigns.project,
        do: ~p"/p/#{socket.assigns.project.slug}/dashboard",
        else: ~p"/dashboard"

    params = [range: range] ++ if(q != "", do: [q: q], else: [])
    base <> "?" <> URI.encode_query(params)
  end

  defp pct(nil), do: "—"
  defp pct(f), do: "#{round(f * 100)}%"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} current_path={@current_path}>
      <div class="flex flex-wrap items-center justify-between gap-3 pb-3">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">Dashboard</h1>
          <p class="text-xs text-base-content/60">
            {if @project, do: @project.name, else: "All projects"} · last {@range} · {Format.number(
              @summary.builds
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

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6" id="headline">
        <.tile
          label="Builds"
          value={Format.number(@summary.builds)}
          sub={"#{@summary.running} running"}
        />
        <.tile
          label="Success rate"
          value={pct(@summary.success_rate)}
          sub={"#{@summary.failed} failed · #{@summary.aborted} aborted"}
          tone={tone(@summary.success_rate)}
        />
        <.tile label="p50 duration" value={Format.duration(@summary.p50)} sub="finished builds" />
        <.tile label="p90 duration" value={Format.duration(@summary.p90)} sub="finished builds" />
        <.tile label="p99 duration" value={Format.duration(@summary.p99)} sub="finished builds" />
        <.tile
          label="Cache hit rate"
          value={pct(@summary.cache_hit_rate)}
          sub={"#{@summary.users} users"}
        />
      </div>

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

      <div class="mt-4 grid gap-4 lg:grid-cols-2">
        <.panel title="Builds over time" id="panel-builds">
          <.stacked_bars
            id="chart-builds"
            points={@series}
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
        <.panel title="Duration percentiles" id="panel-durations">
          <.lines
            id="chart-durations"
            points={@series}
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
        <.panel
          :for={{name, series} <- @segment_series}
          title={"#{name}: p50 / p90 / p99"}
          id={"panel-segment-#{name}"}
        >
          <.lines
            id={"chart-segment-#{name}"}
            points={series}
            series={[
              {:p50, "text-sky-500", "p50"},
              {:p90, "text-amber-500", "p90"},
              {:p99, "text-rose-500", "p99"}
            ]}
          />
        </.panel>
        <.panel title="Remote cache hit rate" id="panel-cache">
          <.lines
            id="chart-cache"
            points={
              Enum.map(@series, &%{&1 | cache_hit_rate: &1.cache_hit_rate && &1.cache_hit_rate * 100})
            }
            series={[{:cache_hit_rate, "text-primary", "cache hit rate"}]}
            label_fun={&"#{round(&1)}%"}
            max={100}
          />
        </.panel>
        <.panel title="Execution strategy" id="panel-strategy">
          <.hbars id="chart-strategy" items={@strategy} />
        </.panel>
        <.panel title="Failures by exit code" id="panel-failures">
          <.hbars id="chart-failures" items={@failures} class="text-rose-500" />
        </.panel>
        <.panel title="Most failing targets" id="panel-targets">
          <.hbars
            id="chart-targets"
            items={Enum.map(@failing_targets, &{&1.label, &1.failures})}
            class="text-rose-500"
          />
        </.panel>
        <.panel title="Builds per user" id="panel-users">
          <table class="w-full text-xs">
            <tbody class="divide-y divide-base-300/60">
              <tr :for={u <- @by_user}>
                <td class="py-1 font-mono">{u.user}</td><td class="py-1 text-right tabular-nums">
                  {Format.number(u.builds)}
                </td><td class="py-1 text-right tabular-nums text-rose-600 dark:text-rose-400">
                  {if u.failed > 0, do: "#{u.failed} failed"}
                </td><td class="py-1 text-right font-mono tabular-nums">{Format.duration(u.p50)}</td>
              </tr>
              <tr :if={@by_user == []}>
                <td class="py-1 text-base-content/50">nothing in this window</td>
              </tr>
            </tbody>
          </table>
        </.panel>
        <.panel title="Slowest builds" id="panel-slowest">
          <table class="w-full text-xs">
            <tbody class="divide-y divide-base-300/60">
              <tr :for={inv <- @slowest}>
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
              <tr :if={@slowest == []}>
                <td class="py-1 text-base-content/50">nothing in this window</td>
              </tr>
            </tbody>
          </table>
        </.panel>
        <.panel title="Builds by hour (UTC)" id="panel-hours">
          <.stacked_bars
            id="chart-hours"
            points={Enum.map(@by_hour, fn {h, n} -> %{bucket: "#{h}h", builds: n} end)}
            series={[{:builds, "text-primary"}]}
          />
        </.panel>
        <.panel title="Bazel versions" id="panel-versions">
          <.hbars id="chart-versions" items={@versions} />
        </.panel>
      </div>
    </Layouts.app>
    """
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

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :tone, :atom, default: :neutral

  defp tile(assigns) do
    ~H"""
    <div class="rounded-md border border-base-300 px-3 py-2">
      <div class="text-[11px] uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class={["text-xl font-semibold tabular-nums", tone_text(@tone)]}>{@value}</div>
      <div :if={@sub} class="text-[11px] text-base-content/50">{@sub}</div>
    </div>
    """
  end

  defp tone(nil), do: :neutral
  defp tone(rate) when rate >= 0.9, do: :good
  defp tone(rate) when rate >= 0.7, do: :warn
  defp tone(_), do: :bad

  defp tone_text(:good), do: "text-emerald-600 dark:text-emerald-400"
  defp tone_text(:warn), do: "text-amber-600 dark:text-amber-400"
  defp tone_text(:bad), do: "text-rose-600 dark:text-rose-400"
  defp tone_text(_), do: nil
end
