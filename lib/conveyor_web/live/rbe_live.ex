defmodule ConveyorWeb.RbeLive do
  @moduledoc """
  "RBE opportunity": would a shared cache or remote build execution save work, for a
  project (`/p/:slug/rbe`) or a cache group (`/groups/:name/rbe`). Every number carries
  its standing: exact (from execution logs, for the builds that uploaded one), estimated
  (wall time exact, cores assumed) or a bound (from the event stream alone).
  """
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents, only: [empty: 1]
  import ConveyorWeb.Charts, only: [hbars: 1]

  alias Conveyor.Accounts.Scope, as: Viewer
  alias Conveyor.ExecLog.Properties
  alias Conveyor.Rbe.{Groups, Reread, Settings}
  alias ConveyorWeb.{Format, RbeReport}

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
       page_title: "RBE opportunity",
       admin?: project != nil and Viewer.can_admin_project?(viewer, project),
       global_admin?: viewer.admin?
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> assign(range: RbeReport.range(params["range"]), current_path: URI.parse(uri).path)
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
      form:
        settings &&
          to_form(%{
            "cores" => Settings.cores_text(settings),
            "pipeline_key" => settings.pipeline_key || "",
            "tolerance_s" => Integer.to_string(settings.tolerance_s),
            "cores_properties" => Settings.names_text(settings),
            "cores_unit" => settings.cores_property.unit,
            "cache_group" => (assigns.group && assigns.group.name) || ""
          })
    )
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket),
    do:
      {:noreply,
       push_patch(socket, to: socket.assigns.current_path <> "?range=" <> RbeReport.range(range))}

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
            ~w(cores pipeline_key tolerance_s cache_group cores_properties cores_unit)
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

  defp core(ms) when ms >= 3_600_000 * 10, do: "#{Format.number(round(ms / 3_600_000))} core-h"
  defp core(ms) when ms >= 3_600_000, do: "#{Float.round(ms / 3_600_000, 1)} core-h"
  defp core(ms), do: "#{Format.number(round(ms / 1000))} core-s"

  defp per_day(ms, days), do: core(round(ms / days)) <> "/day"

  defp pct(nil), do: "—"
  defp pct(f), do: "#{Float.round(f * 100, 1)}%"

  defp ratio(nil), do: "—"
  defp ratio(f), do: "#{Float.round(f * 1.0, 1)}×"

  defp cores(nil), do: "—"
  defp cores(c), do: "#{Float.round(c * 1.0, 2)}"

  defp slug(text), do: String.replace(to_string(text), ~r/[^a-zA-Z0-9]+/, "-")

  defp page_title_for(%{project: %{name: name}}), do: name
  defp page_title_for(%{group: group}), do: "cache group #{group.name}"

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
          <h1 class="text-lg font-semibold tracking-tight">RBE opportunity</h1>
          <p class="text-xs text-base-content/60" id="rbe-subtitle">
            {page_title_for(assigns)} · last {@range}
            <span :if={@project && @group}>
              · in cache group
              <.link navigate={~p"/groups/#{@group.name}/rbe"} class="underline" id="rbe-group-link">
                {@group.name}
              </.link>
            </span>
            <span :if={is_nil(@project) and @report}>· {@report.members} projects</span>
          </p>
        </div>
        <div
          class="flex items-center gap-1 rounded-md border border-base-300 p-0.5 text-xs"
          id="rbe-range-picker"
        >
          <button
            :for={r <- RbeReport.ranges()}
            type="button"
            id={"rbe-range-#{r}"}
            phx-click="range"
            phx-value-range={r}
            aria-selected={to_string(@range == r)}
            class={[
              "rounded px-2.5 py-1 transition-colors",
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
        <.coverage report={@report} />

        <div
          :if={@report.coverage.logs > 0}
          class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3"
          id="rbe-headline"
        >
          <.tile id="tile-cache-gap" label="Cache opportunity" standing={:exact} tone={:good}>
            <:value>{per_day(@report.cache.gap.core_ms, @report.days)}</:value>
            A shared cache recovers this; RBE not required. Hit rate {pct(@report.cache.actual_rate)} actual, {pct(
              @report.cache.ideal_rate
            )} ideal. {core(@report.cache.same_project.core_ms)} redone inside a project, {core(
              @report.cache.cross_project.core_ms
            )} already finished
            by another project of the group.
          </.tile>
          <.tile id="tile-racing" label="Racing duplicates" standing={:exact} tone={:warn}>
            <:value>{per_day(@report.racing.remotable.core_ms, @report.days)}</:value>
            Only RBE recovers this: {Format.number(@report.racing.remotable.n)} executions started
            while the same action was still running elsewhere ({pct(@report.racing.time_share)} of executed time). Within {@report.racing.uncertain.tolerance_s} s of the boundary: {Format.number(
              @report.racing.uncertain.racing.n
            )} racing, {Format.number(@report.racing.uncertain.sequential.n)} sequential.
          </.tile>
          <.tile id="tile-cold" label="Cold machines" standing={:exact}>
            <:value>{per_day(@report.cache.cold.core_ms, @report.days)}</:value>
            Part of the cache opportunity: duplicates executed in the first three builds of a
            host ({Format.number(@report.cache.cold.n)} executions).
          </.tile>
          <.tile id="tile-hit-rate" label="Hit rate, actual → ideal" standing={:exact}>
            <:value>{pct(@report.cache.actual_rate)} → {pct(@report.cache.ideal_rate)}</:value>
            By count, of {Format.number(@report.cache.spawns)} spawns; {pct(@report.cache.rbe_rate)} with in-flight deduplication. By time, {pct(
              @report.cache.gap_time_share
            )} of executed
            wall time was a result a cache already had.
          </.tile>
          <.tile id="tile-not-remotable" label="Outside any cache" standing={:exact}>
            <:value>
              {core(@report.not_dedupable.uncacheable.core_ms + @report.not_dedupable.failed.core_ms)}
            </:value>
            Not cacheable {core(@report.not_dedupable.uncacheable.core_ms)}, failed {core(
              @report.not_dedupable.failed.core_ms
            )}. May not run remotely: {core(@report.not_dedupable.nonremote.core_ms)} ({core(
              @report.racing.local.core_ms
            )} of it raced).
          </.tile>
          <.tile id="tile-parallelism" label="Parallelism headroom" standing={:bound}>
            <:value>{ratio(@report.parallelism && @report.parallelism.bound)}</:value>
            Action time ÷ critical path: the most cores a build could keep busy. Achieved {ratio(
              @report.parallelism && @report.parallelism.achieved
            )} (action time ÷ execution
            phase).
          </.tile>
        </div>

        <.panel :if={@report.coverage.logs > 0} id="panel-cache-gap" title="Cache opportunity">
          <:note>
            Executions whose result another execution of the same action key had already
            finished. Wall time is exact; core time is wall × cores per action.
          </:note>
          <table class="w-full text-sm">
            <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="py-1 font-medium">Sequential duplicates</th>
                <th class="py-1 text-right font-medium">Executions</th>
                <th class="py-1 text-right font-medium">Wall</th>
                <th class="py-1 text-right font-medium">Core time</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
              <tr
                :for={
                  {id, label, cell} <- [
                    {"gap-same", "within the project", @report.cache.same_project},
                    {"gap-cross", "across projects of the group", @report.cache.cross_project},
                    {"gap-cold", "of both: on a host's first three builds", @report.cache.cold},
                    {"gap-total", "total", @report.cache.gap}
                  ]
                }
                id={id}
              >
                <td class="py-1.5 font-sans">{label}</td>
                <td class="py-1.5 text-right">{Format.number(cell.n)}</td>
                <td class="py-1.5 text-right">{Format.duration(cell.ms)}</td>
                <td class="py-1.5 text-right">{core(cell.core_ms)}</td>
              </tr>
            </tbody>
          </table>
        </.panel>

        <.panel :if={@report.mnemonics != []} id="panel-rbe-mnemonics" title="By kind of action">
          <:note>
            Sorted by core time lost to duplicates. Cores: the average assumed, and where it comes from.
          </:note>
          <.cores_coverage coverage={@report.cores_coverage} settings={@settings} />
          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
                <tr>
                  <th class="py-1 font-medium">Mnemonic</th>
                  <th class="py-1 text-right font-medium">Executed</th>
                  <th class="py-1 text-right font-medium">Hits</th>
                  <th class="py-1 text-right font-medium">Wall</th>
                  <th class="py-1 text-right font-medium">Cores</th>
                  <th class="py-1 text-right font-medium">Core time</th>
                  <th class="py-1 text-right font-medium">Racing</th>
                  <th class="py-1 text-right font-medium">Sequential</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
                <tr :for={m <- Enum.take(@report.mnemonics, 30)} id={"mnemonic-#{slug(m.mnemonic)}"}>
                  <td class="py-1.5">{m.mnemonic}</td>
                  <td class="py-1.5 text-right">{Format.number(m.executed.n)}</td>
                  <td class="py-1.5 text-right">{Format.number(m.hits)}</td>
                  <td class="py-1.5 text-right">{Format.duration(m.executed.ms)}</td>
                  <td class="py-1.5 text-right" title={m.cores_source}>
                    {cores(m.cores)}
                    <span class="font-sans text-base-content/50">
                      {m.cores_source}{if m.exact_share && m.exact_share > 0 && m.exact_share < 1,
                        do: " (#{pct(m.exact_share)} of wall by exec property)"}
                    </span>
                  </td>
                  <td class="py-1.5 text-right">{core(m.executed.core_ms)}</td>
                  <td class="py-1.5 text-right">{core(m.racing.core_ms)}</td>
                  <td class="py-1.5 text-right">{core(m.sequential.core_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <div class="grid gap-4 lg:grid-cols-2">
          <.panel
            :if={@report.targets != []}
            id="panel-rbe-targets"
            title="Targets that repeat the most work"
          >
            <:note>Core time of duplicate executions (the top targets of each hour, summed).</:note>
            <table class="w-full text-sm">
              <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
                <tr :for={{t, i} <- Enum.with_index(@report.targets)} id={"rbe-target-#{i}"}>
                  <td class="max-w-0 truncate py-1.5" title={t.target}>
                    {t.target}
                    <span :if={is_nil(@project)} class="font-sans text-base-content/50">{t.project}</span>
                  </td>
                  <td class="py-1.5 pl-3 text-right whitespace-nowrap">
                    {core(t.racing.core_ms)}
                    <span class="font-sans text-base-content/50">racing</span>
                  </td>
                  <td class="py-1.5 pl-3 text-right whitespace-nowrap">
                    {core(t.sequential.core_ms)}
                    <span class="font-sans text-base-content/50">sequential</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </.panel>

          <.panel
            :if={@group && @report.coverage.logs > 0}
            id="panel-rbe-projects"
            title="Projects of the group"
          >
            <:note>
              Core time each project executed again, and the share of its executed time whose
              action another project also executed. Whose finished work it repeated is listed
              under each project.
            </:note>
            <table class="w-full text-sm">
              <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
                <tr>
                  <th class="py-1 font-medium">Project</th>
                  <th class="py-1 text-right font-medium">Racing</th>
                  <th class="py-1 text-right font-medium">Own</th>
                  <th class="py-1 text-right font-medium">Others'</th>
                  <th class="py-1 text-right font-medium">Shared</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
                <tr :for={p <- Enum.take(@report.projects.rows, 15)} id={"rbe-project-#{p.id}"}>
                  <td class="py-1.5 font-sans">
                    {p.name}
                    <div
                      :if={p.from != []}
                      class="text-[11px] text-base-content/50"
                      id={"rbe-from-#{p.id}"}
                    >
                      repeats {Enum.map_join(
                        Enum.take(p.from, 5),
                        ", ",
                        &"#{&1.name} #{core(&1.cell.core_ms)}"
                      )}
                    </div>
                  </td>
                  <td class="py-1.5 text-right">{core(p.racing.core_ms)}</td>
                  <td class="py-1.5 text-right">{core(p.sequential.core_ms)}</td>
                  <td class="py-1.5 text-right">{core(p.cross.core_ms)}</td>
                  <td class="py-1.5 text-right">{pct(p.shared_share)}</td>
                </tr>
                <tr :if={@report.projects.others} id="rbe-project-others">
                  <td class="py-1.5 font-sans text-base-content/60">
                    {@report.projects.others.count} other projects
                  </td>
                  <td class="py-1.5 text-right">{core(@report.projects.others.racing.core_ms)}</td>
                  <td class="py-1.5 text-right">
                    {core(@report.projects.others.sequential.core_ms)}
                  </td>
                  <td class="py-1.5 text-right">{core(@report.projects.others.cross.core_ms)}</td>
                  <td class="py-1.5 text-right">—</td>
                </tr>
              </tbody>
            </table>
          </.panel>

          <.panel :if={@report.pipelines != []} id="panel-rbe-pipelines" title="Racing by pipeline">
            <:note>Racing core time per value of the pipeline tag.</:note>
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
              keys, so no cache could match them. Needs a <code>commit</code> tag.
            </:note>
            <dl class="grid grid-cols-2 gap-2 text-xs">
              <dt class="text-base-content/60">Near-miss executions</dt>
              <dd class="text-right font-mono" id="rbe-near-count">
                {Format.number(@report.near.n)} · {Format.duration(@report.near.ms)}
              </dd>
              <dt class="text-base-content/60">
                Executions of actions with more than one output set
              </dt>
              <dd class="text-right font-mono" id="rbe-nondet-count">
                {Format.number(@report.nondet.n)} · {Format.duration(@report.nondet.ms)}
              </dd>
            </dl>
            <ul class="mt-2 space-y-1 text-xs">
              <li :for={{e, i} <- Enum.with_index(@report.near.examples)} id={"rbe-near-#{i}"}>
                <span class="font-mono">{e["target"]}</span>
                {e["mnemonic"]} ·
                <.link navigate={~p"/invocation/#{e["invocation"]}/actions"} class="underline">this build</.link>
                against
                <.link navigate={~p"/invocation/#{e["first"]}/actions"} class="underline">the first</.link>
                (the input diff is on the Actions tab)
              </li>
            </ul>
          </.panel>
        </div>

        <.fleet report={@report} />
        <.settings
          :if={@admin?}
          form={@form}
          global_admin?={@global_admin?}
          properties={@properties}
          reread={@reread}
          range={@range}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :report, :map, required: true

  defp coverage(assigns) do
    ~H"""
    <div id="rbe-coverage" class="rounded-md border border-base-300 bg-base-200/40 px-3 py-2 text-xs">
      <span class="font-medium">
        {Format.number(@report.coverage.logs)} of {Format.number(@report.coverage.builds)} finished builds
      </span>
      in this window uploaded an execution log{if @report.coverage.builds > 0,
        do: " (#{Format.percent(@report.coverage.logs, @report.coverage.builds)})"}.
      <span :if={@report.coverage.logs > 0}>
        Numbers marked <.standing kind={:exact} /> are exact for those builds and say nothing about
        the others; savings are core time of actions, not build minutes.
        <span :if={@report.keys["fallback"]} id="rbe-fallback-keys">
          {Format.number(@report.keys["fallback"])} executions had no action digest from Bazel
          (no cache configured) and are matched by Conveyor's own key.
        </span>
      </span>
      <span :if={@report.coverage.logs == 0}>
        Without logs only the bound below is known.
      </span>
    </div>
    <.empty
      :if={@report.coverage.logs == 0}
      icon="hero-document-magnifying-glass"
      title="No execution logs in this window"
    >
      <span id="rbe-enable">
        Add <code class="font-mono">--execution_log_compact_file=exec.log.zst</code>
        to every build
        of a pipeline and upload the file with
        <code class="font-mono">tools/bes-upload-profile --execution-log</code>
        (docs: Bazel setup, "RBE opportunity"). Duplicates can only be found between builds that
        both uploaded a log.
      </span>
    </.empty>
    """
  end

  attr :coverage, :map, required: true
  attr :settings, :map, default: nil

  # How much of what executed states its own cores, and through which property names.
  defp cores_coverage(assigns) do
    ~H"""
    <p id="rbe-cores-coverage" class="mb-3 text-xs text-base-content/70">
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

  attr :report, :map, required: true

  defp fleet(assigns) do
    assigns = assign(assigns, fleet: assigns.report.fleet)

    ~H"""
    <.panel id="panel-rbe-fleet" title="From the event stream alone">
      <:note>
        <.standing kind={:bound} /> Every build reports this without any change to CI. It counts
        what executed, not what was a duplicate: an upper bound of what a cache or RBE could save.
      </:note>
      <div class="grid gap-4 lg:grid-cols-3">
        <div id="rbe-fleet-share">
          <h3 class="mb-2 text-xs font-medium">Share of spawns executed, per build</h3>
          <div class="flex h-20 items-end gap-1">
            <div
              :for={{n, i} <- Enum.with_index(@fleet.share)}
              class="flex-1 rounded-t bg-primary/70 transition-all hover:bg-primary"
              style={"height: #{bar(n, @fleet.share)}%"}
              title={"#{i * 10}–#{i * 10 + 10}% executed: #{n} builds"}
            >
            </div>
          </div>
          <div class="mt-1 flex justify-between text-[10px] text-base-content/50">
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
        <div id="rbe-fleet-hosts">
          <h3 class="mb-2 text-xs font-medium">Cold machines: a host's first builds</h3>
          <table class="w-full text-xs">
            <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="py-1 font-medium">Build on host</th>
                <th class="py-1 text-right font-medium">Builds</th>
                <th class="py-1 text-right font-medium">Executed / build</th>
                <th class="py-1 text-right font-medium">CPU / build</th>
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
      <div :if={@fleet.mnemonics != []} class="mt-4 overflow-x-auto" id="rbe-fleet-mnemonics">
        <table class="w-full text-sm">
          <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="py-1 font-medium">Mnemonic</th>
              <th class="py-1 text-right font-medium">Actions run or fetched</th>
              <th class="py-1 text-right font-medium">Created</th>
              <th class="py-1 text-right font-medium">CPU time (measured by Bazel)</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/70 font-mono text-xs tabular-nums">
            <tr :for={m <- Enum.take(@fleet.mnemonics, 15)}>
              <td class="py-1.5">{m.mnemonic}</td>
              <td class="py-1.5 text-right">{Format.number(m.executed)}</td>
              <td class="py-1.5 text-right">{Format.number(m.created)}</td>
              <td class="py-1.5 text-right">
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
  attr :range, :string, required: true

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
            label="Cache group (projects that should share one cache)"
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
          <p class="mt-2 text-[11px] leading-snug text-base-content/60" id="rbe-cores-property-note">
            The first name a spawn carries with a readable value wins; names match in any case;
            blank restores the built-in list. The property is read when an execution log is
            parsed and stored per action, so a change applies to <span class="font-medium text-base-content/80">logs parsed from now on</span>;
            builds already parsed keep what they had until their stored log is read again (below).
          </p>
        </fieldset>
        <div class="sm:col-span-2">
          <button
            type="submit"
            id="rbe-settings-save"
            class="rounded-md bg-base-content px-3 py-1.5 text-xs font-medium text-base-100 transition-opacity hover:opacity-90"
          >Save</button>
        </div>
      </.form>

      <div class="mt-4 grid gap-4 border-t border-base-300 pt-4 lg:grid-cols-2">
        <div id="rbe-properties">
          <h3 class="text-xs font-medium">Exec properties seen in this project's logs</h3>
          <p
            :if={@properties == []}
            class="mt-1 text-xs text-base-content/60"
            id="rbe-properties-empty"
          >
            None yet: no log parsed since this version carried platform properties. Bazel
            writes them for actions with <code class="font-mono">exec_properties</code>
            (on the target or the execution platform).
          </p>
          <table :if={@properties != []} class="mt-1 w-full text-xs">
            <thead class="text-left text-[11px] uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="py-1 font-medium">Name</th>
                <th class="py-1 text-right font-medium">Spawns in its last log</th>
                <th class="py-1 pl-3 font-medium">Example</th>
                <th class="py-1 text-right font-medium">Last seen</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300/70 font-mono tabular-nums">
              <tr :for={{p, i} <- Enum.with_index(@properties)} id={"rbe-property-#{i}"}>
                <td class="py-1">{p.name}</td>
                <td class="py-1 text-right">{Format.number(p.spawns)}</td>
                <td class="py-1 pl-3">
                  {p.sample || "—"}
                </td>
                <td class="py-1 text-right font-sans text-base-content/60">
                  {Calendar.strftime(p.last_seen_at, "%Y-%m-%d %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@properties != []} class="mt-1 text-[11px] text-base-content/50">
            Examples are shown only for short, plain values; anything that looks like a
            credential is never stored.
          </p>
        </div>
        <div id="rbe-reread">
          <h3 class="text-xs font-medium">Builds already parsed</h3>
          <p class="mt-1 text-xs text-base-content/60">
            Reads the cores again from the stored execution logs of this window's builds
            (last {@range}; the {Reread.max()} most recent at most), with the saved names and
            unit. Each log is parsed again in the background, behind new uploads; nothing else
            about the builds changes.
          </p>
          <button
            type="button"
            id="rbe-reread-button"
            phx-click="reread"
            disabled={@reread == 0}
            data-confirm={"Parse the stored execution logs of #{@reread} builds again with the saved cores declaration?"}
            class="mt-2 rounded-md border border-base-300 px-3 py-1.5 text-xs font-medium transition-colors hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-50"
          >Re-read cores from stored logs ({@reread} builds)</button>
        </div>
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
      <p :if={@note != []} class="mb-3 mt-0.5 text-xs text-base-content/60">{render_slot(@note)}</p>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :standing, :atom, required: true
  attr :tone, :atom, default: :neutral
  slot :value, required: true
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <div
      class="rounded-md border border-base-300 px-3 py-2 transition-shadow hover:shadow-sm"
      id={@id}
    >
      <div class="flex items-center justify-between text-[11px] uppercase tracking-wide text-base-content/50">
        <span>{@label}</span>
        <.standing kind={@standing} />
      </div>
      <div class={[
        "text-xl font-semibold tabular-nums",
        @tone == :good && "text-emerald-600 dark:text-emerald-400",
        @tone == :warn && "text-amber-600 dark:text-amber-400"
      ]}>
        {render_slot(@value)}
      </div>
      <p class="mt-1 text-[11px] leading-snug text-base-content/60">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :kind, :atom, required: true

  defp standing(assigns) do
    ~H"""
    <span
      class={[
        "rounded px-1 py-px text-[10px] font-medium normal-case tracking-normal",
        @kind == :exact && "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
        @kind == :bound && "bg-base-300 text-base-content/70"
      ]}
      title={
        if(@kind == :exact,
          do: "wall time and counts exact for builds with a log; core time is wall × cores",
          else: "an upper bound, not a measurement of duplicates"
        )
      }
    >{if @kind == :exact, do: "exact wall · cores as stated", else: "bound"}</span>
    """
  end
end
