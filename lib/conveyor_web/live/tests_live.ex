defmodule ConveyorWeb.TestsLive do
  @moduledoc "Test health across builds: flaky, failing and slow tests in a window."
  use ConveyorWeb, :live_view

  alias Conveyor.Metrics.{Scope, Tests}
  alias Conveyor.Projects
  alias Conveyor.Query
  alias ConveyorWeb.Format

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

    {:ok, assign(socket, projects: projects, project: project, page_title: "Tests")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    range = if params["range"] in Scope.ranges(), do: params["range"], else: "7d"
    q = String.trim(params["q"] || "")
    query = Query.parse!(q)
    project = socket.assigns.project
    scope = Scope.new(range, project && project.id, query)
    rows = Tests.overview(scope)

    {:noreply,
     assign(socket,
       range: range,
       q: q,
       current_path: URI.parse(uri).path,
       rows: rows,
       flaky: Enum.count(rows, &(&1.health == "flaky")),
       failing: Enum.count(rows, &(&1.health == "failing"))
     )}
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket),
    do: {:noreply, push_patch(socket, to: page_path(socket, range, socket.assigns.q))}

  def handle_event("search", %{"q" => q}, socket),
    do:
      {:noreply, push_patch(socket, to: page_path(socket, socket.assigns.range, String.trim(q)))}

  defp page_path(socket, range, q) do
    base =
      if socket.assigns.project, do: ~p"/p/#{socket.assigns.project.slug}/tests", else: ~p"/tests"

    base <> "?" <> URI.encode_query([range: range] ++ if(q != "", do: [q: q], else: []))
  end

  defp health_classes("flaky"), do: "bg-amber-500/10 text-amber-700 dark:text-amber-300"
  defp health_classes("failing"), do: "bg-rose-500/10 text-rose-700 dark:text-rose-300"
  defp health_classes(_), do: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} current_path={@current_path}>
      <div class="flex flex-wrap items-center justify-between gap-3 pb-3">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">Tests</h1>
          <p class="text-xs text-base-content/60">
            {length(@rows)} tests · {@flaky} flaky · {@failing} failing · last {@range}
          </p>
        </div>
        <form
          phx-submit="search"
          class="flex min-w-0 flex-1 items-center gap-2 sm:max-w-md"
          id="tests-search"
        >
          <input
            type="search"
            name="q"
            id="tests-q"
            value={@q}
            placeholder="filter builds, e.g. ci:true"
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

      <div class="overflow-x-auto rounded-md border border-base-300">
        <table class="w-full text-sm" id="tests-table">
          <thead class="bg-base-200/60 text-left text-[11px] uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2 font-medium">Health</th>
              <th class="px-3 py-2 font-medium">Test</th>
              <th class="px-3 py-2 text-right font-medium">Runs</th>
              <th class="px-3 py-2 text-right font-medium">Passed</th>
              <th class="px-3 py-2 text-right font-medium">Failed</th>
              <th class="px-3 py-2 text-right font-medium">Flaky</th>
              <th class="px-3 py-2 text-right font-medium">Timeout</th>
              <th class="px-3 py-2 text-right font-medium">p50</th>
              <th class="px-3 py-2 text-right font-medium">Max</th>
              <th class="px-3 py-2 font-medium">Last build</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
            <tr :for={r <- @rows} id={"test-#{:erlang.phash2(r.label)}"} data-health={r.health}>
              <td class="px-3 py-1.5">
                <span class={["rounded px-1.5 py-0.5 font-sans font-medium", health_classes(r.health)]}>{r.health}</span>
              </td>
              <td class="px-3 py-1.5">{r.label}</td>
              <td class="px-3 py-1.5 text-right">{r.runs}</td>
              <td class="px-3 py-1.5 text-right text-emerald-600 dark:text-emerald-400">
                {r.passed}
              </td>
              <td class="px-3 py-1.5 text-right text-rose-600 dark:text-rose-400">{r.failed}</td>
              <td class="px-3 py-1.5 text-right text-amber-600 dark:text-amber-400">{r.flaky}</td>
              <td class="px-3 py-1.5 text-right">{r.timeout}</td>
              <td class="px-3 py-1.5 text-right">{Format.duration(r.p50)}</td>
              <td class="px-3 py-1.5 text-right">{Format.duration(r.max)}</td>
              <td class="px-3 py-1.5">
                <.link
                  navigate={~p"/invocation/#{r.last_invocation_id}"}
                  class="text-base-content/60 hover:underline"
                >{String.slice(r.last_invocation_id, 0, 8)}</.link>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="10" class="px-3 py-8 text-center text-base-content/50">
                No test results in this window.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
