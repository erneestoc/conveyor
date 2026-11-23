defmodule ConveyorWeb.RbeLive do
  @moduledoc """
  "Duplicate work": executions that repeated an action another execution had finished
  (sequential) or was still running (racing), for a project (`/p/:slug/duplicate-work`)
  or a cache group (`/groups/:name/duplicate-work`). The page shows metrics and their
  definitions, not advice. Every number carries its standing: exact (from execution
  logs, for the builds that uploaded one), estimated (wall time exact, cores assumed) or
  a bound (from the event stream alone).

  The feature was named "RBE opportunity"; the module, the DOM ids (`rbe-*`) and the
  audit actions (`project.rbe_settings`, `project.rbe_reread`) keep that name.
  """
  use ConveyorWeb, :live_view

  import ConveyorWeb.Charts, only: [hbars: 1]

  alias Conveyor.Accounts.Scope, as: Viewer
  alias Conveyor.ExecLog.Properties
  alias Conveyor.Rbe.{Groups, Reread, Settings}
  alias ConveyorWeb.{Format, RbeReport}

  # The columns the projects of a group sort by.
  @sorts [
    {"name", "Project"},
    {"wasted", "Repeated"},
    {"racing", "Racing"},
    {"own", "Own"},
    {"others", "Others'"},
    {"shared", "Shared"}
  ]

  @impl true
  def mount(params, _session, socket) do
    viewer = socket.assigns.current_scope
    projects = ConveyorWeb.Auth.visible_projects(viewer)

    {project, group} =
      case params do
        %{"slug" => slug} ->
          project =
            ConveyorWeb.Auth.visible_project_by_slug(viewer, slug) ||
              raise ConveyorWeb.NotFoundError, "no project #{slug}"

          {project, Groups.of(project)}

        %{"name" => name} ->
          group = Groups.get_by_name(name)

          if is_nil(group) or Viewer.visible_projects(viewer, Groups.members(group)) == [],
            do: raise(ConveyorWeb.NotFoundError, "no cache group #{name}")

          {nil, group}
      end

    {:ok,
     assign(socket,
       projects: projects,
       project: project,
       group: group,
       page_title: "Duplicate work",
       admin?: project != nil and Viewer.can_admin_project?(viewer, project),
       global_admin?: viewer.admin?,
       projects_q: "",
       projects_sort: "wasted",
       projects_page: 1
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    uri = URI.parse(uri)

    {:noreply,
     socket
     |> assign(
       range: RbeReport.range(params["range"]),
       current_path: uri.path,
       # The address the viewer reached the page at: what a CI job uploads to.
       origin: URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})
     )
     |> load()}
  end

  # Loaded once per view, in the connected mount (as the dashboard does).
  defp load(%{assigns: assigns} = socket) do
    viewer = assigns.current_scope

    report =
      cond do
        not connected?(socket) -> nil
        assigns.project -> RbeReport.project(viewer, assigns.project, assigns.range)
        true -> RbeReport.group(viewer, assigns.group, assigns.range)
      end

    settings = assigns.project && Settings.get(assigns.project)
    admin? = assigns.admin? and connected?(socket)

    assign(socket,
      report: report,
      settings: settings,
      # Only a project's admin reads which property names its logs carry.
      properties: if(admin?, do: Properties.list(assigns.project.id), else: []),
      reread: if(admin?, do: Reread.count(assigns.project, window_start(assigns.range)), else: 0),
      upload_key?: admin? and upload_key?(assigns.project),
      form:
        settings &&
          to_form(%{
            "cores" => Settings.cores_text(settings),
            "pipeline_key" => settings.pipeline_key || "",
            "tolerance_s" => Integer.to_string(settings.tolerance_s),
            "cores_properties" => Settings.names_text(settings),
            "cores_unit" => settings.cores_property.unit,
            "analysis_only" => settings.analysis_only,
            "keep_action_events" => settings.keep_action_events,
            "row_days" => Integer.to_string(settings.row_days),
            "cache_group" => (assigns.group && assigns.group.name) || ""
          })
    )
  end

  # CI uploads logs with a key of the `upload` scope; one that is revoked or expired
  # does not count.
  defp upload_key?(project) do
    now = DateTime.utc_now()

    project
    |> Conveyor.Projects.list_api_keys()
    |> Enum.any?(&("upload" in &1.scopes and Conveyor.Projects.ApiKey.active?(&1, now)))
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket),
    do:
      {:noreply,
       push_patch(socket, to: socket.assigns.current_path <> "?range=" <> RbeReport.range(range))}

  def handle_event("projects_filter", %{"q" => q}, socket),
    do: {:noreply, assign(socket, projects_q: String.slice(q, 0, 100), projects_page: 1)}

  def handle_event("projects_sort", %{"sort" => sort}, socket) do
    sort = if Enum.any?(@sorts, &(elem(&1, 0) == sort)), do: sort, else: "wasted"
    {:noreply, assign(socket, projects_sort: sort, projects_page: 1)}
  end

  def handle_event("projects_page", %{"page" => page}, socket) do
    case Integer.parse(page) do
      {n, ""} -> {:noreply, assign(socket, projects_page: n)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save", %{"cores" => _} = params, %{assigns: %{admin?: true}} = socket) do
    project = Conveyor.Projects.get_project!(socket.assigns.project.id)

    with {:ok, project} <- Settings.put(project, params),
         {:ok, project} <- put_group(socket, project, params["cache_group"]) do
      Conveyor.Audit.log(socket.assigns.current_scope, "project.rbe_settings",
        subject: {"project", project.id},
        project_id: project.id,
        metadata:
          Map.take(
            params,
            ~w(cores pipeline_key tolerance_s cache_group cores_properties cores_unit analysis_only row_days keep_action_events)
          )
      )

      {:noreply,
       socket
       |> assign(project: project, group: Groups.of(project))
       |> put_flash(:info, "Settings saved")
       |> load()}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("reread", _params, %{assigns: %{admin?: true}} = socket) do
    project = socket.assigns.project
    builds = Reread.enqueue!(project, window_start(socket.assigns.range))

    Conveyor.Audit.log(socket.assigns.current_scope, "project.rbe_reread",
      subject: {"project", project.id},
      project_id: project.id,
      metadata: %{
        builds: builds,
        range: socket.assigns.range,
        cores_properties: Settings.names_text(socket.assigns.settings),
        cores_unit: socket.assigns.settings.cores_property.unit
      }
    )

    {:noreply,
     put_flash(
       socket,
       :info,
       "Reading #{builds} stored logs again; the numbers follow as each is parsed"
     )}
  end

  # Settings and re-reads are a project admin's; anyone else's event changes nothing.
  def handle_event(event, _params, socket) when event in ["save", "reread"],
    do: {:noreply, socket}

  defp window_start(range), do: Conveyor.Metrics.Scope.new(range, nil).from

  # Membership of a cache group is a global admin's decision (it shares totals between
  # projects); anyone else's form does not carry the field, and it is ignored if it does.
  defp put_group(%{assigns: %{global_admin?: true}}, project, name) when is_binary(name),
    do: Groups.put(project, name)

  defp put_group(_socket, project, _name), do: {:ok, project}

  # --- formatting ------------------------------------------------------------------------------

  # Core time as a number and its unit: seconds up to an hour, then hours (a core-day is
  # not a unit anybody budgets in).
  defp core_parts(ms) when ms >= 3_600_000 * 100,
    do: {Format.number(round(ms / 3_600_000)), "core-h"}

  defp core_parts(ms) when ms >= 3_600_000,
    do: {:erlang.float_to_binary(ms / 3_600_000, decimals: 1), "core-h"}

  defp core_parts(ms), do: {Format.number(round(ms / 1000)), "core-s"}

  defp core(ms) do
    {number, unit} = core_parts(ms)
    number <> " " <> unit
  end

  # In a table a zero is a dash: the eye finds the rows that have something.
  defp core_cell(0), do: "—"
  defp core_cell(ms), do: core(ms)

  # Per logged day: the window's total over its UTC days that have a parsed log.
  defp per_day(_ms, 0), do: "—"
  defp per_day(ms, days), do: core(round(ms / days)) <> " per logged day"

  defp cold_is_all?(cache), do: cache.cold.core_ms > 0 and cache.cold.core_ms == cache.gap.core_ms

  # The exact figure behind a rounded one, for the tooltip.
  defp core_exact(ms), do: "#{Format.number(round(ms / 1000))} core-seconds"

  defp pct(nil), do: "—"
  defp pct(f), do: "#{:erlang.float_to_binary(f * 100.0, decimals: 1)}%"

  defp ratio(nil), do: "—"
  defp ratio(f), do: "#{:erlang.float_to_binary(f * 1.0, decimals: 1)}×"

  defp cores(nil), do: "—"

  defp cores(c) do
    if Float.round(c * 1.0, 2) == Float.round(c * 1.0, 0),
      do: Integer.to_string(round(c)),
      else: :erlang.float_to_binary(c * 1.0, decimals: 2)
  end

  defp count_and_time(%{n: 0}), do: "none"
  defp count_and_time(cell), do: "#{Format.number(cell.n)} · #{Format.duration(cell.ms)}"

  defp slug(text), do: String.replace(to_string(text), ~r/[^a-zA-Z0-9]+/, "-")

  defp page_title_for(%{project: %{name: name}}), do: name
  defp page_title_for(%{group: group}), do: "cache group #{group.name}"

  # --- the projects of a group: found, sorted, paged ---------------------------------------------

  defp project_rows(rows, q, sort) do
    q = q |> String.trim() |> String.downcase()

    rows
    |> Enum.filter(&(q == "" or String.contains?(String.downcase(&1.name), q)))
    |> Enum.sort_by(&sort_key(sort, &1))
  end

  defp sort_key("name", r), do: {0, r.name}
  defp sort_key("racing", r), do: {-r.racing.core_ms, r.name}
  defp sort_key("own", r), do: {-r.sequential.core_ms, r.name}
  defp sort_key("others", r), do: {-r.cross.core_ms, r.name}
  defp sort_key("shared", r), do: {-(r.shared_share || 0.0), r.name}
  defp sort_key(_wasted, r), do: {-repeated(r), r.name}

  defp repeated(r), do: r.racing.core_ms + r.sequential.core_ms + r.cross.core_ms

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
        <div class="min-w-0">
          <h1 class="text-lg font-semibold tracking-tight">Duplicate work</h1>
          <p class="text-xs text-base-content/70" id="rbe-subtitle">
            {page_title_for(assigns)} · last {@range}
            <span :if={@project && @group}>
              · in cache group
              <.link
                navigate={~p"/groups/#{@group.name}/duplicate-work"}
                class="underline underline-offset-2 hover:text-base-content"
                id="rbe-group-link"
              >
                {@group.name}
              </.link>
            </span>
            <span :if={is_nil(@project) and @report}>· {@report.members} projects</span>
          </p>
        </div>
        <div
          class="flex items-center gap-1 rounded-md border border-base-300 p-0.5 text-xs"
          id="rbe-range-picker"
          role="group"
          aria-label="Window"
        >
          <button
            :for={r <- RbeReport.ranges()}
            type="button"
            id={"rbe-range-#{r}"}
            phx-click="range"
            phx-value-range={r}
            aria-pressed={to_string(@range == r)}
            class={[
              "rounded px-2.5 py-1 transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
              @range == r && "bg-base-content text-base-100",
              @range != r && "text-base-content/70 hover:bg-base-200"
            ]}
          >{r}</button>
        </div>
      </div>

      <div
        :if={is_nil(@report)}
        id="rbe-loading"
        class="py-12 text-center text-sm text-base-content/60"
      >
        Loading…
      </div>

      <div :if={@report} id="rbe-report" class="space-y-4">
        <.coverage report={@report} origin={@origin} />

        <div :if={@report.coverage.logs > 0} id="rbe-headline" class="space-y-3">
          <div class="grid gap-3 lg:grid-cols-2">
            <.hero
              id="tile-cache-gap"
              tone={:good}
              label="Sequential duplicates"
              claim="Executed although the same action had already finished elsewhere."
              help="The result existed when the execution started. A cache shared by the machines involved serves such a result."
              ms={@report.cache.gap.core_ms}
              logged_days={@report.logged_days}
              window_days={@report.window_days}
              range={@range}
              coverage={@report.cores_coverage}
            >
              <:row label="Executions">
                {Format.number(@report.cache.gap.n)} executions · {Format.duration(
                  @report.cache.gap.ms
                )} wall
              </:row>
              <:row label="After an execution of the same project">
                {core(@report.cache.same_project.core_ms)}
              </:row>
              <:row :if={@group} label="After an execution of another project of the group only">
                {core(@report.cache.cross_project.core_ms)}
              </:row>
              <:row label="Of it, on a host's first three builds">
                {core(@report.cache.cold.core_ms)}{if cold_is_all?(@report.cache),
                  do: " (all of it)"}
              </:row>
            </.hero>
            <.hero
              id="tile-racing"
              tone={:warn}
              label="Racing duplicates"
              claim="Executed while the same action was still running elsewhere."
              help="No result existed yet when the execution started, so a cache has nothing to serve. An executor that merges identical actions in flight (remote build execution, RBE) runs such an action once."
              ms={@report.racing.remotable.core_ms}
              logged_days={@report.logged_days}
              window_days={@report.window_days}
              range={@range}
              coverage={@report.cores_coverage}
            >
              <:row label="Executions">
                {Format.number(@report.racing.remotable.n)} executions · {pct(
                  @report.racing.time_share
                )} of executed wall time
              </:row>
              <:row label={"Within #{@report.racing.uncertain.tolerance_s} s of the boundary (clock tolerance)"}>
                {Format.number(@report.racing.uncertain.racing.n)} racing, {Format.number(
                  @report.racing.uncertain.sequential.n
                )} sequential
              </:row>
              <:row label="Raced but may not run remotely (not counted)">
                {core(@report.racing.local.core_ms)}
              </:row>
            </.hero>
          </div>

          <div class={[
            "grid gap-3 sm:grid-cols-2",
            if(cold_is_all?(@report.cache), do: "lg:grid-cols-3", else: "lg:grid-cols-4")
          ]}>
            <.tile id="tile-hit-rate" label="Cache hit rate" standing={:exact}>
              <:value>
                <dl class="mt-1 grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-3 gap-y-0.5 text-xs font-normal">
                  <dt>today</dt>
                  <dd id="hit-rate-today" class="text-right text-base font-semibold">
                    {pct(@report.cache.hit_rate.today)}
                  </dd>
                  <dt>perfect cache</dt>
                  <dd id="hit-rate-perfect-cache" class="text-right text-base font-semibold">
                    {pct(@report.cache.hit_rate.perfect_cache)}
                  </dd>
                  <dt>with in-flight deduplication</dt>
                  <dd id="hit-rate-in-flight" class="text-right text-base font-semibold">
                    {pct(@report.cache.hit_rate.with_in_flight_deduplication)}
                  </dd>
                </dl>
              </:value>
              Share of {Format.number(@report.cache.spawns)} spawns, by count. Today: served
              from cache. Perfect cache: if every finished result were shared. With in-flight
              deduplication: also merging identical actions still running. By time, {pct(
                @report.cache.gap_time_share
              )} of executed wall time repeated a finished result.
            </.tile>
            <.tile
              :if={not cold_is_all?(@report.cache)}
              id="tile-cold"
              label="Cold machines"
              standing={:exact}
            >
              <:value>{per_day(@report.cache.cold.core_ms, @report.logged_days)}</:value>
              Part of the sequential duplicates: {Format.number(@report.cache.cold.n)} executed
              in the first three builds of a host.
            </.tile>
            <.tile id="tile-not-remotable" label="Outside any cache" standing={:exact}>
              <:value>
                {core(
                  @report.not_dedupable.uncacheable.core_ms + @report.not_dedupable.failed.core_ms
                )}
              </:value>
              In the window: not cacheable {core(@report.not_dedupable.uncacheable.core_ms)}, failed {core(
                @report.not_dedupable.failed.core_ms
              )}. May not run remotely: {core(@report.not_dedupable.nonremote.core_ms)}.
            </.tile>
            <.tile id="tile-parallelism" label="Parallelism headroom" standing={:bound}>
              <:value>{ratio(@report.parallelism && @report.parallelism.bound)}</:value>
              Action time ÷ critical path: the most cores a build could keep busy. Achieved {ratio(
                @report.parallelism && @report.parallelism.achieved
              )} (action time ÷ execution
              phase).
            </.tile>
          </div>
        </div>

        <.panel :if={@report.coverage.logs > 0} id="panel-cache-gap" title="Sequential duplicates">
          <:note>
            Executions whose result another execution of the same action key had already
            finished, in the whole window. Wall time is exact; core time is wall × cores per
            action.
          </:note>
          <div class="overflow-x-auto">
            <table class="w-full min-w-[30rem] text-sm">
              <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
                <tr>
                  <th scope="col" class="py-1 font-medium">First execution finished</th>
                  <th scope="col" class="py-1 text-right font-medium">Executions</th>
                  <th scope="col" class="py-1 text-right font-medium">Wall</th>
                  <th scope="col" class="py-1 text-right font-medium">Core time</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
                <tr
                  :for={
                    {id, label, cell, class} <-
                      [
                        {"gap-same", "within the project", @report.cache.same_project, nil},
                        {"gap-cross", "across projects of the group", @report.cache.cross_project,
                         nil},
                        {"gap-total", "total", @report.cache.gap, "font-semibold"},
                        {"gap-cold", "of the total: on a host's first three builds",
                         @report.cache.cold, "text-base-content/70"}
                      ]
                  }
                  :if={id != "gap-cross" or @group != nil or cell.n > 0}
                  id={id}
                  class={class}
                >
                  <td class="py-1.5 pr-3 font-sans">{label}</td>
                  <td class="py-1.5 text-right">{Format.number(cell.n)}</td>
                  <td class="py-1.5 pl-3 text-right">{Format.duration(cell.ms)}</td>
                  <td class="py-1.5 pl-3 text-right" title={core_exact(cell.core_ms)}>
                    {core_cell(cell.core_ms)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel :if={@report.mnemonics != []} id="panel-rbe-mnemonics" title="By kind of action">
          <:note>
            Sorted by core time of duplicate executions. Cores is the average used for the
            mnemonic; the last column says where it comes from.
          </:note>
          <.cores_coverage coverage={@report.cores_coverage} settings={@settings} />
          <div class="overflow-x-auto">
            <table class="w-full min-w-[46rem] text-sm">
              <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
                <tr>
                  <th scope="col" class="py-1 font-medium">Mnemonic</th>
                  <th scope="col" class="py-1 pl-3 text-right font-medium">Executed</th>
                  <th scope="col" class="py-1 pl-3 text-right font-medium">Hits</th>
                  <th scope="col" class="py-1 pl-3 text-right font-medium">Wall</th>
                  <th scope="col" class="py-1 pl-3 text-right font-medium">Core time</th>
                  <th
                    scope="col"
                    class="py-1 pl-3 text-right font-medium text-amber-700 dark:text-amber-400"
                  >
                    Racing
                  </th>
                  <th
                    scope="col"
                    class="py-1 pl-3 text-right font-medium text-emerald-700 dark:text-emerald-400"
                  >
                    Sequential
                  </th>
                  <th scope="col" class="py-1 pl-6 text-right font-medium">Cores</th>
                  <th scope="col" class="py-1 pl-2 font-medium">from</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
                <tr
                  :for={m <- Enum.take(@report.mnemonics, 30)}
                  id={"mnemonic-#{slug(m.mnemonic)}"}
                  class="transition-colors hover:bg-base-200/50"
                >
                  <td class="py-1.5">{m.mnemonic}</td>
                  <td class="py-1.5 pl-3 text-right">{Format.number(m.executed.n)}</td>
                  <td class="py-1.5 pl-3 text-right">{Format.number(m.hits)}</td>
                  <td class="py-1.5 pl-3 text-right">{Format.duration(m.executed.ms)}</td>
                  <td class="py-1.5 pl-3 text-right" title={core_exact(m.executed.core_ms)}>
                    {core_cell(m.executed.core_ms)}
                  </td>
                  <td class="py-1.5 pl-3 text-right" title={core_exact(m.racing.core_ms)}>
                    {core_cell(m.racing.core_ms)}
                  </td>
                  <td class="py-1.5 pl-3 text-right" title={core_exact(m.sequential.core_ms)}>
                    {core_cell(m.sequential.core_ms)}
                  </td>
                  <td class="py-1.5 pl-6 text-right">{cores(m.cores)}</td>
                  <td class="py-1.5 pl-2 font-sans text-base-content/70">
                    {m.cores_source}<span :if={
                      m.exact_share && m.exact_share > 0 && m.exact_share < 1
                    }> · {pct(m.exact_share)} of wall stated</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={length(@report.mnemonics) > 30} class="mt-2 text-xs text-base-content/60">
            The 30 mnemonics with the most duplicate core time; {length(@report.mnemonics) - 30} more are in the JSON.
          </p>
        </.panel>

        <.projects
          :if={@group && @report.coverage.logs > 0}
          projects={@report.projects}
          q={@projects_q}
          sort={@projects_sort}
          page={@projects_page}
        />

        <div class="grid gap-4 lg:grid-cols-2">
          <.panel
            :if={@report.targets != []}
            id="panel-rbe-targets"
            title="Targets that repeat the most work"
          >
            <:note>
              Core time of duplicate executions in the window (the top targets of each hour,
              summed).
            </:note>
            <table class="w-full table-fixed text-sm">
              <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
                <tr>
                  <th scope="col" class="py-1 font-medium">Target</th>
                  <th
                    scope="col"
                    class="w-24 py-1 text-right font-medium text-amber-700 dark:text-amber-400"
                  >
                    Racing
                  </th>
                  <th
                    scope="col"
                    class="w-24 py-1 text-right font-medium text-emerald-700 dark:text-emerald-400"
                  >
                    Sequential
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
                <tr :for={{t, i} <- Enum.with_index(@report.targets)} id={"rbe-target-#{i}"}>
                  <td class="py-1.5 pr-2 break-all">
                    {t.target}
                    <span :if={is_nil(@project)} class="font-sans text-base-content/60">
                      {t.project}
                    </span>
                  </td>
                  <td class="py-1.5 text-right align-top whitespace-nowrap">
                    {core_cell(t.racing.core_ms)}
                  </td>
                  <td class="py-1.5 text-right align-top whitespace-nowrap">
                    {core_cell(t.sequential.core_ms)}
                  </td>
                </tr>
              </tbody>
            </table>
          </.panel>

          <div class="space-y-4">
            <.panel :if={@report.pipelines != []} id="panel-rbe-pipelines" title="Racing by pipeline">
              <:note>
                Racing core time in the window, per value of the pipeline tag (executions that
                may run remotely, as in the headline).
              </:note>
              <.hbars
                id="rbe-pipelines"
                items={Enum.map(@report.pipelines, &{&1.value, &1.core_ms})}
                label_fun={&core/1}
                class="text-amber-500"
              />
            </.panel>

            <.panel
              :if={@report.coverage.logs > 0}
              id="panel-rbe-near"
              title="Near misses and determinism"
            >
              <:note>
                A near miss: one output of one target at one commit executed under two action
                keys, so no cache could match them. Needs a <code class="font-mono">commit</code> tag.
              </:note>
              <dl class="grid grid-cols-[minmax(0,1fr)_auto] gap-x-4 gap-y-2 text-xs">
                <dt class="text-base-content/70">Near-miss executions</dt>
                <dd class="text-right font-mono tabular-nums" id="rbe-near-count">
                  {count_and_time(@report.near)}
                </dd>
                <dt class="text-base-content/70">
                  Executions of actions with more than one output set (not deterministic)
                </dt>
                <dd class="text-right font-mono tabular-nums" id="rbe-nondet-count">
                  {count_and_time(@report.nondet)}
                </dd>
              </dl>
              <ul class="mt-3 space-y-1.5 text-xs">
                <li :for={{e, i} <- Enum.with_index(@report.near.examples)} id={"rbe-near-#{i}"}>
                  <span class="font-mono break-all">{e["target"]}</span>
                  <span class="text-base-content/70">{e["mnemonic"]}</span>
                  ·
                  <.link
                    navigate={~p"/invocation/#{e["invocation"]}/actions"}
                    class="underline underline-offset-2"
                  >this build</.link>
                  against
                  <.link
                    navigate={~p"/invocation/#{e["first"]}/actions"}
                    class="underline underline-offset-2"
                  >the first</.link>
                  <span class="text-base-content/60">(the input diff is on the Actions tab)</span>
                </li>
              </ul>
            </.panel>
          </div>
        </div>

        <.fleet report={@report} />
        <.settings
          :if={@admin?}
          form={@form}
          global_admin?={@global_admin?}
          properties={@properties}
          reread={@reread}
          settings={@settings}
          project={@project}
          range={@range}
          origin={@origin}
          upload_key?={@upload_key?}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :report, :map, required: true
  attr :origin, :string, required: true

  defp coverage(assigns) do
    ~H"""
    <div
      id="rbe-coverage"
      class="rounded-md border border-base-300 bg-base-200/40 px-3 py-2 text-xs leading-relaxed"
    >
      <span class="font-medium">
        {Format.number(@report.coverage.logs)} of {Format.number(@report.coverage.builds)} finished builds
      </span>
      in this window uploaded an execution log{if @report.coverage.builds > 0,
        do: " (#{Format.percent(@report.coverage.logs, @report.coverage.builds)})"}.
      <span :if={@report.coverage.logs > 0}>
        Numbers marked <.standing kind={:exact} />
        are exact in wall time for those builds (core time is wall × the cores each action
        states or is estimated to use) and say nothing about the others; numbers marked
        <.standing kind={:bound} /> are an upper bound from the event stream. All figures are
        core time of actions, not build minutes.
        <span :if={@report.keys["fallback"]} id="rbe-fallback-keys">
          {Format.number(@report.keys["fallback"])} executions had no action digest from Bazel
          (no cache configured) and are matched by Conveyor's own key.
        </span>
      </span>
      <span :if={@report.coverage.logs == 0}>
        Without logs only the bound below is known.
      </span>
    </div>
    <div
      :if={@report.coverage.logs == 0}
      id="rbe-empty"
      class="rounded-md border border-dashed border-base-300 px-4 py-8"
    >
      <div class="mx-auto max-w-2xl">
        <div class="flex items-center gap-2">
          <.icon name="hero-document-magnifying-glass" class="size-5 text-base-content/50" />
          <h2 class="text-sm font-semibold">No execution logs in this window</h2>
        </div>
        <p class="mt-1 text-sm text-base-content/70" id="rbe-enable">
          A duplicate is found only between two builds that both uploaded a log. Logs from
          every build of a pipeline show all of its duplicates; logs from a sample of builds
          show the duplicates among the sampled builds only.
        </p>
        <.ci_snippet id="rbe-ci-snippet-empty" origin={@origin} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :origin, :string, required: true
  # Whether the project has a live key that may upload; nil where that is not the
  # viewer's to know (the empty state anyone sees).
  attr :upload_key?, :boolean, default: nil

  # What a CI job adds to upload its execution log. The key is a placeholder: a real one
  # is never rendered.
  defp ci_snippet(assigns) do
    ~H"""
    <div id={@id} class="mt-3">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-xs font-medium">Upload the execution log from CI</h3>
        <button
          type="button"
          id={"#{@id}-copy"}
          phx-hook=".CopyText"
          data-copy-from={"#{@id}-text"}
          class="rounded-md border border-base-300 px-2 py-1 text-[11px] font-medium transition-colors hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <.icon name="hero-clipboard-document-micro" class="size-3.5" />
          <span data-copy-label>Copy</span>
        </button>
      </div>
      <pre
        id={"#{@id}-text"}
        class="mt-1 overflow-x-auto rounded-md border border-base-300 bg-base-200/60 p-3 font-mono text-[11px] leading-relaxed"
      >{ci_text(@origin)}</pre>
      <p class="mt-1.5 text-[11px] leading-snug text-base-content/70">
        <code class="font-mono">CONVEYOR_UPLOAD_KEY</code>
        is a placeholder for an API key with the <code class="font-mono">upload</code>
        scope (Project settings); keep it in the CI's secret store. A key with only
        <code class="font-mono">ingest</code>
        or <code class="font-mono">read</code>
        is answered 403, which <code class="font-mono">curl -sf</code>
        would hide: the recipe prints the status. The <code class="font-mono">content-type</code>
        header is required: curl's default form encoding is refused. The flag does not
        change cache keys: with Bazel 9.2 (checked 2026-11-22) a build without the flag hit
        every action cached by a build with it, and toggling it did not discard the analysis
        cache.
      </p>
      <p
        :if={@upload_key? == false}
        id={"#{@id}-no-key"}
        class="mt-1.5 flex items-start gap-1.5 rounded-md border border-amber-500/40 bg-amber-500/5 px-2 py-1.5 text-[11px] leading-snug"
      >
        <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0 text-amber-600" />
        <span>
          This project has no live API key with the <code class="font-mono">upload</code>
          scope: create one in Project settings before CI can upload a log.
        </span>
      </p>
      <p
        :if={@upload_key? == true}
        id={"#{@id}-has-key"}
        class="mt-1.5 flex items-center gap-1.5 text-[11px] text-base-content/70"
      >
        <.icon name="hero-check-circle-micro" class="size-3.5 text-emerald-600" />
        This project has a live API key with the upload scope.
      </p>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const source = document.getElementById(this.el.dataset.copyFrom)
              const label = this.el.querySelector("[data-copy-label]")
              navigator.clipboard.writeText(source.innerText).then(() => {
                label.textContent = "Copied"
                setTimeout(() => { label.textContent = "Copy" }, 1500)
              })
            })
          }
        }
      </script>
    </div>
    """
  end

  defp ci_text(origin) do
    """
    # .bazelrc
    build:ci --execution_log_compact_file=/tmp/exec.log.zst

    # CI job: every build of the pipeline, with an id the job chooses
    ID=$(uuidgen | tr 'A-Z' 'a-z')
    bazel build --config=ci --invocation_id="$ID" //...

    # afterwards, also when the build failed; the key needs the upload scope
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \\
      -H "x-api-key: $CONVEYOR_UPLOAD_KEY" \\
      -H "content-type: application/octet-stream" \\
      --data-binary @/tmp/exec.log.zst \\
      "#{origin}/api/v1/invocations/$ID/artifacts/execution.log.zst")
    echo "execution log upload: HTTP $code (201 stored, 403 key lacks the upload scope)"\
    """
  end

  attr :coverage, :map, required: true
  attr :settings, :map, default: nil

  # How much of what executed states its own cores, and through which property names.
  defp cores_coverage(assigns) do
    ~H"""
    <p id="rbe-cores-coverage" class="mb-3 text-xs leading-relaxed text-base-content/70">
      <span class="font-medium text-base-content">
        {pct(@coverage.exact_share)} of executed wall time
      </span>
      ({Format.duration(@coverage.exact.ms)} of {Format.duration(@coverage.executed.ms)}<span
        :if={@coverage.exact.n}
        id="rbe-cores-coverage-count"
      >; {Format.number(@coverage.exact.n)} of {Format.number(@coverage.executed.n)} executions</span>)
      states its cores in an exec property<span :if={@settings} id="rbe-cores-names">
        (<span class="font-mono">{Enum.join(@settings.cores_property.names, ", ")}</span>, unit {@settings.cores_property.unit})</span>.
      <span :if={@coverage.fallbacks != []}>
        The rest is estimated: {Enum.map_join(@coverage.fallbacks, ", ", fn f ->
          "#{f.source} #{Format.duration(f.ms)}" <>
            if(f.n, do: " (#{Format.number(f.n)})", else: "")
        end)}; a cores-per-mnemonic setting replaces those estimates.
      </span>
    </p>
    """
  end

  attr :projects, :map, required: true
  attr :q, :string, required: true
  attr :sort, :string, required: true
  attr :page, :integer, required: true

  @page_size 25

  # A group can have hundreds of member projects: found by name, sorted by any column,
  # 25 at a time, with the sum of what is listed and of the whole group.
  defp projects(assigns) do
    rows = project_rows(assigns.projects.rows, assigns.q, assigns.sort)
    pages = max(ceil(length(rows) / @page_size), 1)
    page = assigns.page |> max(1) |> min(pages)

    assigns =
      assign(assigns,
        sorts: @sorts,
        found: length(rows),
        all: length(assigns.projects.rows),
        pages: pages,
        page: page,
        shown: Enum.slice(rows, (page - 1) * @page_size, @page_size),
        total: %{
          racing: rows |> Enum.map(& &1.racing.core_ms) |> Enum.sum(),
          own: rows |> Enum.map(& &1.sequential.core_ms) |> Enum.sum(),
          others: rows |> Enum.map(& &1.cross.core_ms) |> Enum.sum()
        }
      )

    ~H"""
    <.panel id="panel-rbe-projects" title="Projects of the group">
      <:note>
        Core time each project executed again in the window: racing, after itself (own),
        after another project had finished the action (others'), and the share of its
        executed time whose action another project also executed (shared).
      </:note>
      <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
        <.form
          for={%{}}
          as={:projects}
          id="rbe-projects-filter"
          phx-change="projects_filter"
          phx-submit="projects_filter"
          class="w-full sm:w-64"
        >
          <label for="rbe-projects-q" class="sr-only">Find a project</label>
          <input
            type="search"
            name="q"
            id="rbe-projects-q"
            value={@q}
            placeholder="Find a project"
            phx-debounce="200"
            autocomplete="off"
            class="w-full rounded-md border border-base-300 bg-base-100 px-2.5 py-1.5 text-xs placeholder:text-base-content/50 focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary"
          />
        </.form>
        <p class="text-xs text-base-content/70" id="rbe-projects-count">
          {Format.number(@found)} of {Format.number(@all)} projects<span :if={@projects.others}>
            you may see; {@projects.others.count} more are summed without a name
          </span>
        </p>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[40rem] text-sm">
          <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
            <tr>
              <th
                :for={{key, label} <- @sorts}
                scope="col"
                class={["py-1 font-medium", key != "name" && "pl-3 text-right"]}
                aria-sort={
                  if(@sort == key, do: if(key == "name", do: "ascending", else: "descending"))
                }
              >
                <button
                  type="button"
                  id={"rbe-projects-sort-#{key}"}
                  phx-click="projects_sort"
                  phx-value-sort={key}
                  class={[
                    "uppercase tracking-wide transition-colors hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
                    @sort == key && "text-base-content"
                  ]}
                >
                  {label}<span :if={@sort == key} aria-hidden="true">{if key == "name",
                    do: " ↑",
                    else: " ↓"}</span>
                </button>
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
            <tr
              :for={p <- @shown}
              id={"rbe-project-#{p.id}"}
              class="transition-colors hover:bg-base-200/50"
            >
              <td class="py-1.5 font-sans">
                {p.name}
                <div
                  :if={p.from != []}
                  class="text-[11px] text-base-content/60"
                  id={"rbe-from-#{p.id}"}
                >
                  after {Enum.map_join(
                    Enum.take(p.from, 3),
                    ", ",
                    &"#{if(&1.id == p.id, do: "itself", else: &1.name)} #{core(&1.cell.core_ms)}"
                  )}{if length(p.from) > 3, do: ", and #{length(p.from) - 3} more"}
                </div>
              </td>
              <td class="py-1.5 pl-3 text-right align-top font-semibold">
                {core_cell(repeated(p))}
              </td>
              <td class="py-1.5 pl-3 text-right align-top">{core_cell(p.racing.core_ms)}</td>
              <td class="py-1.5 pl-3 text-right align-top">{core_cell(p.sequential.core_ms)}</td>
              <td class="py-1.5 pl-3 text-right align-top">{core_cell(p.cross.core_ms)}</td>
              <td class="py-1.5 pl-3 text-right align-top">{pct(p.shared_share)}</td>
            </tr>
            <tr :if={@shown == []} id="rbe-projects-none">
              <td colspan="6" class="py-4 text-center font-sans text-base-content/60">
                No project matches.
              </td>
            </tr>
            <tr :if={@projects.others} id="rbe-project-others">
              <td class="py-1.5 font-sans text-base-content/70">
                {@projects.others.count} projects you may not see
              </td>
              <td class="py-1.5 pl-3 text-right font-semibold">
                {core_cell(
                  @projects.others.racing.core_ms + @projects.others.sequential.core_ms +
                    @projects.others.cross.core_ms
                )}
              </td>
              <td class="py-1.5 pl-3 text-right">{core_cell(@projects.others.racing.core_ms)}</td>
              <td class="py-1.5 pl-3 text-right">
                {core_cell(@projects.others.sequential.core_ms)}
              </td>
              <td class="py-1.5 pl-3 text-right">{core_cell(@projects.others.cross.core_ms)}</td>
              <td class="py-1.5 pl-3 text-right">—</td>
            </tr>
          </tbody>
          <tfoot :if={@found > 1} class="border-t border-base-300 font-mono text-xs tabular-nums">
            <tr id="rbe-projects-total">
              <td class="py-1.5 font-sans font-medium">
                Sum of the {Format.number(@found)} listed
              </td>
              <td class="py-1.5 pl-3 text-right font-semibold">
                {core_cell(@total.racing + @total.own + @total.others)}
              </td>
              <td class="py-1.5 pl-3 text-right">{core_cell(@total.racing)}</td>
              <td class="py-1.5 pl-3 text-right">{core_cell(@total.own)}</td>
              <td class="py-1.5 pl-3 text-right">{core_cell(@total.others)}</td>
              <td></td>
            </tr>
          </tfoot>
        </table>
      </div>
      <nav
        :if={@pages > 1}
        id="rbe-projects-pages"
        aria-label="Pages of projects"
        class="mt-3 flex items-center justify-between text-xs"
      >
        <button
          type="button"
          id="rbe-projects-prev"
          phx-click="projects_page"
          phx-value-page={@page - 1}
          disabled={@page == 1}
          class="rounded-md border border-base-300 px-2.5 py-1 font-medium transition-colors hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-50"
        >Previous</button>
        <span class="text-base-content/70">Page {@page} of {@pages}</span>
        <button
          type="button"
          id="rbe-projects-next"
          phx-click="projects_page"
          phx-value-page={@page + 1}
          disabled={@page == @pages}
          class="rounded-md border border-base-300 px-2.5 py-1 font-medium transition-colors hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-50"
        >Next</button>
      </nav>
    </.panel>
    """
  end

  attr :report, :map, required: true

  defp fleet(assigns) do
    assigns = assign(assigns, fleet: assigns.report.fleet)

    ~H"""
    <.panel id="panel-rbe-fleet" title="From the event stream alone">
      <:note>
        <.standing kind={:bound} /> Every build reports this without any change to CI. It counts
        what executed, not what was a duplicate: an upper bound on duplicate work.
      </:note>
      <div class="grid gap-x-6 gap-y-5 lg:grid-cols-3">
        <div id="rbe-fleet-share" class="min-w-0">
          <h3 class="mb-2 text-xs font-medium">Share of spawns executed, per build</h3>
          <div
            class="flex h-20 items-end gap-1 border-b border-base-300"
            role="img"
            aria-label={"Builds by share of spawns executed, in tenths: #{Enum.join(@fleet.share, ", ")}"}
          >
            <div
              :for={{n, i} <- Enum.with_index(@fleet.share)}
              class="min-h-px flex-1 rounded-t bg-primary/70 transition-colors hover:bg-primary"
              style={"height: #{bar(n, @fleet.share)}%"}
              title={"#{i * 10}–#{i * 10 + 10}% executed: #{n} builds"}
            >
            </div>
          </div>
          <div class="mt-1 flex justify-between text-[10px] text-base-content/60">
            <span>all cached</span><span>all executed</span>
          </div>
          <p class="mt-2 text-xs text-base-content/70">
            {Format.number(@fleet.executed)} spawns executed, {Format.number(@fleet.hits)} cache
            hits ({pct(@fleet.executed_share)} executed) in {Format.number(@fleet.with_metrics)} builds.
          </p>
        </div>
        <div>
          <h3 class="mb-2 text-xs font-medium">Spawns by runner</h3>
          <.hbars
            id="rbe-fleet-runners"
            items={Enum.map(Enum.take(@fleet.runners, 8), &{&1.name, &1.count})}
          />
        </div>
        <div id="rbe-fleet-hosts" class="min-w-0 overflow-x-auto">
          <h3 class="mb-2 text-xs font-medium">Cold machines: a host's first builds</h3>
          <table class="w-full text-xs">
            <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
              <tr>
                <th scope="col" class="py-1 font-medium">Build on host</th>
                <th scope="col" class="py-1 text-right font-medium">Builds</th>
                <th scope="col" class="py-1 pl-2 text-right font-medium">Executed / build</th>
                <th scope="col" class="py-1 pl-2 text-right font-medium">CPU / build</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300/70 font-mono tabular-nums">
              <tr :for={h <- @fleet.hosts.cold ++ [Map.put(@fleet.hosts.later, :ordinal, "later")]}>
                <td class="py-1 font-sans">
                  {if is_integer(h.ordinal), do: "##{h.ordinal}", else: h.ordinal}
                </td>
                <td class="py-1 text-right">{Format.number(h.builds)}</td>
                <td class="py-1 text-right">{per_build(h.executed, h.builds)}</td>
                <td class="py-1 text-right">{per_build_duration(h.cpu_ms, h.builds)}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@fleet.hosts.excess} class="mt-2 text-xs text-base-content/70" id="rbe-fleet-excess">
            First builds executed {Format.number(@fleet.hosts.excess.executed)} spawns ({Format.duration(
              @fleet.hosts.excess.cpu_ms
            )} of CPU) more than the same number of later builds.
          </p>
        </div>
      </div>
      <div :if={@fleet.mnemonics != []} class="mt-5 overflow-x-auto" id="rbe-fleet-mnemonics">
        <table class="w-full min-w-[34rem] text-sm">
          <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
            <tr>
              <th scope="col" class="py-1 font-medium">Mnemonic</th>
              <th scope="col" class="py-1 pl-3 text-right font-medium">Actions run or fetched</th>
              <th scope="col" class="py-1 pl-3 text-right font-medium">Created</th>
              <th scope="col" class="py-1 pl-3 text-right font-medium">
                CPU time (measured by Bazel)
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
            <tr :for={m <- Enum.take(@fleet.mnemonics, 15)}>
              <td class="py-1.5">{m.mnemonic}</td>
              <td class="py-1.5 pl-3 text-right">{Format.number(m.executed)}</td>
              <td class="py-1.5 pl-3 text-right">{Format.number(m.created)}</td>
              <td class={["py-1.5 pl-3 text-right", m.timed == 0 && "font-sans text-base-content/50"]}>
                {if m.timed > 0, do: Format.duration(m.cpu_ms), else: "not reported"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.panel>
    """
  end

  defp bar(n, all), do: round(n * 100 / max(Enum.max(all), 1))
  defp per_build(_n, 0), do: "—"
  defp per_build(n, builds), do: Format.number(round(n / builds))
  defp per_build_duration(_ms, 0), do: "—"
  defp per_build_duration(ms, builds), do: Format.duration(round(ms / builds))

  attr :form, :map, required: true
  attr :global_admin?, :boolean, required: true
  attr :properties, :list, required: true
  attr :reread, :integer, required: true
  attr :settings, :map, required: true
  attr :project, :map, required: true
  attr :range, :string, required: true
  attr :origin, :string, required: true
  attr :upload_key?, :boolean, required: true

  defp settings(assigns) do
    ~H"""
    <.panel id="rbe-settings" title="Settings">
      <:note>
        Cores per mnemonic replace the estimate wherever an action does not state its own cores.
      </:note>
      <.form for={@form} id="rbe-settings-form" phx-submit="save" class="grid gap-3 sm:grid-cols-2">
        <.input
          field={@form[:cores]}
          type="textarea"
          label="Cores per mnemonic (Mnemonic=cores, one per line)"
          placeholder="TestRunner=4"
        />
        <div class="space-y-3">
          <.input
            field={@form[:pipeline_key]}
            type="text"
            label="Pipeline tag key (optional)"
            placeholder="pipeline"
          />
          <.input
            field={@form[:tolerance_s]}
            type="select"
            label="Clock tolerance (seconds)"
            options={Enum.map(Settings.tolerances(), &{"#{&1} s", Integer.to_string(&1)})}
          />
          <.input
            :if={@global_admin?}
            field={@form[:cache_group]}
            type="text"
            label="Cache group (projects whose executions are compared with each other)"
            placeholder="monorepo"
          />
        </div>
        <fieldset class="rounded-md border border-base-300 p-3 sm:col-span-2" id="rbe-cores-property">
          <legend class="px-1 text-xs font-medium">How this project declares cores per action</legend>
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:cores_properties]}
              type="text"
              label="Exec property names, in order (comma separated)"
              placeholder="cores"
            />
            <.input
              field={@form[:cores_unit]}
              type="select"
              label="Unit of the value"
              options={[
                {"auto: a plain number is cores, 4000m is millicores", "auto"},
                {"cores (4, 0.5)", "cores"},
                {"millicores (4000)", "millicores"}
              ]}
            />
          </div>
          <p class="mt-2 text-[11px] leading-snug text-base-content/70" id="rbe-cores-property-note">
            The first name a spawn carries with a readable value wins; names match in any case;
            blank restores the built-in list. The property is read when an execution log is
            parsed and stored per action, so a change applies to <span class="font-medium text-base-content">logs parsed from now on</span>;
            builds already parsed keep what they had until their stored log is read again (below).
          </p>
        </fieldset>
        <fieldset
          id="rbe-storage"
          class="space-y-2 border-t border-base-300 pt-4 sm:col-span-2"
        >
          <legend class="float-left mb-2 w-full text-xs font-medium">Storage</legend>
          <div class="clear-both flex flex-wrap items-end gap-x-8 gap-y-2 [&_input[type=number]]:w-24">
            <.input
              field={@form[:analysis_only]}
              type="checkbox"
              label="Keep only what the duplicate-work metrics need"
            />
            <.input
              field={@form[:row_days]}
              type="number"
              min="1"
              max="30"
              label="Days per-spawn rows are kept in this mode"
            />
          </div>
          <.input
            field={@form[:keep_action_events]}
            type="checkbox"
            label="Keep per-action events in the raw event stream"
          />
          <p
            id="rbe-action-events-help"
            class="max-w-3xl text-[11px] leading-snug text-base-content/70"
          >
            With <code>--build_event_publish_all_actions</code>
            Bazel sends an event for every action. Unless this is on, the events of
            successful actions (and the empty progress event behind each) are counted but
            not stored with a build's raw events: its Events tab and its event-stream
            download do not contain them. Failed actions are always stored. Measured on
            recorded builds, these events are 77 to 92 % of a stream and 3 to 10 times the
            stored bytes of the rest.
          </p>
          <p class="max-w-3xl text-[11px] leading-snug text-base-content/70">
            When on, logs parsed from now on store no input lists and no output lists (a
            build's Actions tab then cannot show which inputs changed), the uploaded log is
            deleted once it is parsed, and per-spawn rows are kept for the days above
            instead of the project's execution-log retention ({Conveyor.ExecLog.general_retention_days(
              @project
            )} days). The hourly numbers of this page and the action keys stay. An hour's
            numbers are final one hour before its rows expire: a log parsed later is matched
            by later builds and is itself not counted.
            <span
              :if={@settings.late_logs > 0}
              id="rbe-late-logs"
              class="font-medium text-base-content"
            >
              {Format.number(@settings.late_logs)} {if @settings.late_logs == 1,
                do: "log has",
                else: "logs have"} arrived that late.
            </span>
          </p>
        </fieldset>
        <div class="sm:col-span-2">
          <button
            type="submit"
            id="rbe-settings-save"
            phx-disable-with="Saving…"
            class="rounded-md bg-base-content px-3 py-1.5 text-xs font-medium text-base-100 transition-opacity hover:opacity-90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >Save</button>
        </div>
      </.form>

      <div class="mt-4 grid gap-x-6 gap-y-5 border-t border-base-300 pt-4 lg:grid-cols-2">
        <div id="rbe-properties" class="min-w-0">
          <h3 class="text-xs font-medium">Exec properties seen in this project's logs</h3>
          <p
            :if={@properties == []}
            class="mt-1 text-xs text-base-content/70"
            id="rbe-properties-empty"
          >
            None yet: no log parsed since this version carried platform properties. Bazel
            writes them for actions with <code class="font-mono">exec_properties</code>
            (on the target or the execution platform).
          </p>
          <div :if={@properties != []} class="overflow-x-auto">
            <table class="mt-1 w-full min-w-[26rem] text-xs">
              <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
                <tr>
                  <th scope="col" class="py-1 font-medium">Name</th>
                  <th scope="col" class="py-1 pl-3 font-medium">Example</th>
                  <th scope="col" class="py-1 pl-3 text-right font-medium">Spawns in its last log</th>
                  <th scope="col" class="py-1 pl-3 text-right font-medium">Last seen (UTC)</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/70 font-mono tabular-nums">
                <tr :for={{p, i} <- Enum.with_index(@properties)} id={"rbe-property-#{i}"}>
                  <td class="py-1">{p.name}</td>
                  <td class="py-1 pl-3">{p.sample || "—"}</td>
                  <td class="py-1 pl-3 text-right">{Format.number(p.spawns)}</td>
                  <td class="py-1 pl-3 text-right font-sans text-base-content/70">
                    {Calendar.strftime(p.last_seen_at, "%Y-%m-%d %H:%M")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@properties != []} class="mt-1 text-[11px] text-base-content/60">
            Examples are shown only for short, plain values; anything that looks like a
            credential is never stored.
          </p>
        </div>
        <div id="rbe-reread" class="min-w-0">
          <h3 class="text-xs font-medium">Builds already parsed</h3>
          <p class="mt-1 text-xs text-base-content/70">
            Reads the cores again from the stored execution logs of this window's builds
            (last {@range}; the {Reread.max()} most recent at most), with the saved names and
            unit. Each log is parsed again in the background, behind new uploads; nothing else
            about the builds changes.
          </p>
          <p
            :if={@settings.analysis_only}
            id="rbe-reread-unavailable"
            class="mt-1 text-xs font-medium text-base-content/80"
          >
            Not available: this project keeps only what the metrics need, so uploaded logs
            are deleted once parsed and there is nothing to read again.
          </p>
          <button
            type="button"
            id="rbe-reread-button"
            phx-click="reread"
            disabled={@reread == 0 or @settings.analysis_only}
            data-confirm={"Parse the stored execution logs of #{@reread} builds again with the saved cores declaration?"}
            class="mt-2 rounded-md border border-base-300 px-3 py-1.5 text-xs font-medium transition-colors hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary disabled:cursor-not-allowed disabled:opacity-50"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5" />
            Re-read cores from stored logs ({@reread} builds)
          </button>
        </div>
      </div>

      <div class="mt-4 border-t border-base-300 pt-1">
        <.ci_snippet id="rbe-ci-snippet" origin={@origin} upload_key?={@upload_key?} />
      </div>
    </.panel>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :note
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section id={@id} class="rounded-md border border-base-300 p-4">
      <h2 class="text-sm font-semibold">{@title}</h2>
      <p :if={@note != []} class="mb-3 mt-0.5 max-w-prose text-xs text-base-content/70">
        {render_slot(@note)}
      </p>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :claim, :string, required: true
  attr :help, :string, required: true
  attr :tone, :atom, required: true
  attr :ms, :integer, required: true
  attr :logged_days, :integer, required: true
  attr :window_days, :integer, required: true
  attr :range, :string, required: true
  attr :coverage, :map, required: true

  slot :row do
    attr :label, :string, required: true
  end

  # One of the two headline metrics: core time per day, large, with what it is made of,
  # what the number is (claim) and which mechanism addresses the class (help), as facts.
  defp hero(assigns) do
    {number, unit} = core_parts(round(assigns.ms / max(assigns.logged_days, 1)))
    assigns = assign(assigns, number: number, unit: unit)

    ~H"""
    <section
      id={@id}
      class={[
        "rounded-lg border p-4 transition-shadow hover:shadow-sm sm:p-5",
        @tone == :good && "border-emerald-500/40 bg-emerald-500/5",
        @tone == :warn && "border-amber-500/40 bg-amber-500/5"
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <h2 class={[
          "text-xs font-semibold uppercase tracking-wide",
          @tone == :good && "text-emerald-700 dark:text-emerald-300",
          @tone == :warn && "text-amber-700 dark:text-amber-300"
        ]}>
          {@label}
        </h2>
        <.standing kind={:exact} />
      </div>
      <p
        class={[
          "mt-2 flex flex-wrap items-baseline gap-x-2 font-semibold tabular-nums tracking-tight",
          @tone == :good && "text-emerald-700 dark:text-emerald-400",
          @tone == :warn && "text-amber-700 dark:text-amber-400"
        ]}
        title={"#{core_exact(@ms)} in the window ÷ #{@logged_days} logged days"}
      >
        <span class="text-4xl leading-none sm:text-5xl" id={"#{@id}-value"}>{@number}</span>
        <span class="text-base">{@unit} per logged day</span>
      </p>
      <p class="mt-1 text-xs text-base-content/70" id={"#{@id}-days"}>
        {@logged_days} of {@window_days} days have logs (UTC days the window touches)
      </p>
      <p class="mt-2 text-sm font-medium">{@claim}</p>
      <p class="mt-1 text-xs leading-snug text-base-content/70" id={"#{@id}-help"}>{@help}</p>
      <dl class="mt-3 grid grid-cols-1 gap-x-4 border-t border-base-content/10 pt-3 text-xs sm:grid-cols-[minmax(0,1fr)_auto] sm:gap-y-1">
        <dt class="text-base-content/70">In the window (last {@range})</dt>
        <dd class="mb-1.5 font-mono tabular-nums sm:mb-0 sm:text-right">{core(@ms)}</dd>
        <%= for row <- @row do %>
          <dt class="text-base-content/70">{row.label}</dt>
          <dd class="mb-1.5 font-mono tabular-nums sm:mb-0 sm:text-right">{render_slot(row)}</dd>
        <% end %>
      </dl>
      <p class="mt-3 text-[11px] leading-snug text-base-content/70">
        Wall time exact; cores stated by an exec property for {pct(@coverage.exact_share)} of
        executed wall time, estimated for the rest. A logged day is a UTC day with at least
        one build whose execution log was parsed.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :standing, :atom, required: true
  slot :value, required: true
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <div
      class="rounded-md border border-base-300 px-3 py-2.5 transition-shadow hover:shadow-sm"
      id={@id}
    >
      <div class="flex items-center justify-between gap-2 text-[11px] uppercase tracking-wide text-base-content/70">
        <span>{@label}</span>
        <.standing kind={@standing} short />
      </div>
      <div class="mt-0.5 text-xl font-semibold tabular-nums">
        {render_slot(@value)}
      </div>
      <p class="mt-1 text-[11px] leading-snug text-base-content/70">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :short, :boolean, default: false

  defp standing(assigns) do
    ~H"""
    <span
      class={[
        "whitespace-nowrap rounded px-1 py-px text-[10px] font-medium normal-case tracking-normal",
        @kind == :exact && "bg-emerald-500/10 text-emerald-800 dark:text-emerald-300",
        @kind == :bound && "bg-base-300 text-base-content/80"
      ]}
      title={
        if(@kind == :exact,
          do: "wall time and counts exact for builds with a log; core time is wall × cores",
          else: "an upper bound, not a measurement of duplicates"
        )
      }
    >{cond do
      @kind == :bound -> "bound"
      @short -> "exact"
      true -> "exact wall · cores as stated"
    end}</span>
    """
  end
end
