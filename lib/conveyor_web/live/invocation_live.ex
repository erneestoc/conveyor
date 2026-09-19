defmodule ConveyorWeb.InvocationLive do
  @moduledoc """
  One invocation: header with live status, and tabs for overview, log, targets, tests,
  actions, details and raw events. Subscribes to the ingest digests so everything moves
  while the build runs.
  """
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents

  alias Conveyor.Ingest
  alias Conveyor.Ingest.Status
  alias Conveyor.Invocations
  alias Conveyor.Invocations.{Action, Invocation, Target, TestResult}
  alias Conveyor.Projects
  alias ConveyorWeb.Format

  @tabs ~w(overview log timeline targets tests actions metrics details events)
  @events_per_page 100

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    inv = Invocations.get(id) || raise ConveyorWeb.NotFoundError, "no invocation #{id}"
    projects = Projects.list_projects(include_archived: true)
    project = Enum.find(projects, &(&1.id == inv.project_id))

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.invocation_topic(inv.id))

    {:ok,
     socket
     |> assign(
       invocation: inv,
       artifacts: Conveyor.Artifacts.list(inv),
       projects: Enum.reject(projects, & &1.archived_at),
       project: project,
       tab: "overview",
       tabs: @tabs
     )
     |> assign(page_title: Format.command_line(inv), log_subscribed: false, loaded: MapSet.new())
     |> assign(
       failed_targets: [],
       slowest_tests: [],
       metrics: nil,
       runner_counts: [],
       mnemonics: [],
       targets_by_key: %{},
       tests_by_key: %{},
       action_count: 0,
       timeline_actions: [],
       events: [],
       events_page: 1,
       events_total: 0,
       events_pages: 1
     )
     |> stream_configure(:targets, dom_id: &"target-#{:erlang.phash2({&1.label, &1.aspect})}")
     |> stream_configure(:actions, dom_id: &"action-#{&1.seq}")
     |> stream(:targets, [])
     |> stream(:actions, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "overview"
    page = parse_page(params["page"])

    {:noreply,
     socket |> assign(tab: tab, current_path: URI.parse(uri).path) |> load_tab(tab, page)}
  end

  # --- tab data (loaded once per tab; later updates arrive through digests) -------------------

  defp load_tab(socket, "overview", _page) do
    inv = socket.assigns.invocation
    metrics = Invocations.metrics(inv)

    assign(socket,
      failed_targets: Invocations.failed_targets(inv),
      slowest_tests: Invocations.slowest_tests(inv, 8),
      metrics: metrics,
      runner_counts: runner_counts(metrics),
      mnemonics: mnemonics(metrics)
    )
  end

  defp load_tab(socket, "log", _page) do
    if connected?(socket) and not socket.assigns.log_subscribed do
      Phoenix.PubSub.subscribe(Conveyor.PubSub, Ingest.log_topic(socket.assigns.invocation.id))
      assign(socket, log_subscribed: true)
    else
      socket
    end
  end

  defp load_tab(socket, "targets", _page) do
    if loaded?(socket, :targets) do
      socket
    else
      targets = Invocations.targets(socket.assigns.invocation)
      by_key = Map.new(targets, &{{&1.label, &1.aspect}, &1})

      socket
      |> mark_loaded(:targets)
      |> assign(targets_by_key: by_key)
      |> stream(:targets, targets, reset: true)
    end
  end

  defp load_tab(socket, "tests", _page) do
    if loaded?(socket, :tests) do
      socket
    else
      results = Invocations.test_results(socket.assigns.invocation)
      by_key = Map.new(results, &{test_key(&1), &1})
      socket |> mark_loaded(:tests) |> assign(tests_by_key: by_key)
    end
  end

  defp load_tab(socket, "actions", _page) do
    if loaded?(socket, :actions) do
      socket
    else
      actions = Invocations.actions(socket.assigns.invocation)

      socket
      |> mark_loaded(:actions)
      |> assign(action_count: length(actions))
      |> stream(:actions, actions, reset: true)
    end
  end

  defp load_tab(socket, "timeline", _page) do
    socket |> load_tab("tests", 1) |> load_tab("actions", 1)
  end

  defp load_tab(socket, "metrics", _page) do
    assign(socket, metrics: Invocations.metrics(socket.assigns.invocation))
  end

  defp load_tab(socket, "events", page) do
    {events, total} = Invocations.events_page(socket.assigns.invocation, page, @events_per_page)

    rows =
      Enum.map(events, fn {seq, event} ->
        %{
          seq: seq,
          kind: Conveyor.Bep.Event.payload_kind(event),
          json: Protobuf.JSON.encode!(event) |> Jason.decode!() |> Jason.encode!(pretty: true)
        }
      end)

    assign(socket,
      events: rows,
      events_page: page,
      events_total: total,
      events_pages: max(div(total + @events_per_page - 1, @events_per_page), 1)
    )
  end

  defp load_tab(socket, _tab, _page), do: socket

  defp loaded?(socket, key), do: MapSet.member?(socket.assigns.loaded, key)

  defp mark_loaded(socket, key),
    do: assign(socket, loaded: MapSet.put(socket.assigns.loaded, key))

  # --- events --------------------------------------------------------------------------------------

  @impl true
  # The whole log goes to the browser in one event; very large logs are cut to their tail so
  # the page stays responsive (the download link always has everything).
  @log_max_bytes 8 * 1024 * 1024

  def handle_event("log:load", _params, socket) do
    inv = socket.assigns.invocation
    log = Invocations.log(inv)

    {text, truncated} =
      if byte_size(log) > @log_max_bytes do
        {binary_part(log, byte_size(log) - @log_max_bytes, @log_max_bytes), true}
      else
        {log, false}
      end

    {:noreply,
     push_event(socket, "log:reset", %{
       text: text,
       live: not Status.final?(inv.status),
       truncated: truncated
     })}
  end

  # --- live updates ---------------------------------------------------------------------------------

  @impl true
  def handle_info({:invocation_detail, %{invocation: summary} = detail}, socket) do
    inv = struct(socket.assigns.invocation, Map.take(summary, Invocation.__schema__(:fields)))

    socket =
      socket
      |> assign(invocation: inv, page_title: Format.command_line(inv))
      |> apply_targets(detail.targets)
      |> apply_tests(detail.tests)
      |> apply_actions(detail.actions)

    socket =
      if socket.assigns.tab == "overview" and (detail.targets != [] or detail.tests != []),
        do: load_tab(socket, "overview", 1),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:artifacts_changed, id}, socket) do
    inv = Conveyor.Invocations.get!(id)
    {:noreply, assign(socket, invocation: inv, artifacts: Conveyor.Artifacts.list(inv))}
  end

  def handle_info({:log_chunks, chunks}, socket) do
    {:noreply, push_event(socket, "log:append", %{text: IO.iodata_to_binary(chunks)})}
  end

  defp apply_targets(socket, []), do: socket

  defp apply_targets(socket, rows) do
    if loaded?(socket, :targets) do
      {by_key, structs} =
        Enum.reduce(rows, {socket.assigns.targets_by_key, []}, fn attrs, {acc, structs} ->
          key = {attrs.label, Map.get(attrs, :aspect, "")}

          merged =
            struct(Map.get(acc, key, %Target{invocation_id: socket.assigns.invocation.id}), attrs)

          {Map.put(acc, key, merged), [merged | structs]}
        end)

      Enum.reduce(
        structs,
        assign(socket, targets_by_key: by_key),
        &stream_insert(&2, :targets, &1)
      )
    else
      socket
    end
  end

  defp apply_tests(socket, []), do: socket

  defp apply_tests(socket, rows) do
    if loaded?(socket, :tests) do
      by_key =
        Enum.reduce(rows, socket.assigns.tests_by_key, fn attrs, acc ->
          key =
            {attrs.label, Map.get(attrs, :configuration_id, ""), attrs.run, attrs.shard,
             attrs.attempt}

          Map.put(acc, key, struct(Map.get(acc, key, %TestResult{}), attrs))
        end)

      assign(socket, tests_by_key: by_key)
    else
      socket
    end
  end

  defp apply_actions(socket, []), do: socket

  defp apply_actions(socket, rows) do
    if loaded?(socket, :actions) do
      structs = Enum.map(rows, &struct(Action, &1))

      socket =
        assign(socket,
          action_count: socket.assigns.action_count + length(rows),
          timeline_actions: socket.assigns.timeline_actions ++ structs
        )

      Enum.reduce(structs, socket, &stream_insert(&2, :actions, &1))
    else
      socket
    end
  end

  # --- helpers ------------------------------------------------------------------------------------

  defp test_key(%TestResult{} = t), do: {t.label, t.configuration_id, t.run, t.shard, t.attempt}

  defp parse_page(nil), do: 1

  defp parse_page(string) do
    case Integer.parse(string) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp runner_counts(nil), do: []

  defp runner_counts(%{build_metrics: metrics}) do
    metrics
    |> get_in(["actionSummary", "runnerCount"])
    |> List.wrap()
    |> Enum.map(&{&1["name"], &1["count"] || 0})
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp mnemonics(nil), do: []

  defp mnemonics(%{build_metrics: metrics}) do
    metrics
    |> get_in(["actionSummary", "actionData"])
    |> List.wrap()
    |> Enum.map(&{&1["mnemonic"], to_int(&1["actionsExecuted"]), to_int(&1["actionsCreated"])})
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(12)
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  # Groups test attempts by label with an overall verdict.
  defp test_groups(tests_by_key) do
    tests_by_key
    |> Map.values()
    |> Enum.group_by(& &1.label)
    |> Enum.map(fn {label, attempts} ->
      attempts = Enum.sort_by(attempts, &{&1.run, &1.shard, &1.attempt})
      statuses = Enum.map(attempts, & &1.status)

      verdict =
        cond do
          Enum.all?(statuses, &(&1 == "PASSED")) -> "PASSED"
          "PASSED" in statuses -> "FLAKY"
          "TIMEOUT" in statuses -> "TIMEOUT"
          true -> "FAILED"
        end

      %{
        label: label,
        attempts: attempts,
        verdict: verdict,
        duration_ms: attempts |> Enum.map(&(&1.duration_ms || 0)) |> Enum.max(fn -> 0 end),
        cached: Enum.all?(attempts, &(&1.cached_locally or &1.cached_remotely))
      }
    end)
    |> Enum.sort_by(&{&1.verdict == "PASSED", &1.label})
  end

  defp test_status_classes("PASSED"), do: "text-emerald-600 dark:text-emerald-400"
  defp test_status_classes("FLAKY"), do: "text-amber-600 dark:text-amber-400"
  defp test_status_classes("NO_STATUS"), do: "text-base-content/50"
  defp test_status_classes(_), do: "text-rose-600 dark:text-rose-400"

  defp target_status_classes("success"), do: "text-emerald-600 dark:text-emerald-400"
  defp target_status_classes("failed"), do: "text-rose-600 dark:text-rose-400"
  defp target_status_classes(_), do: "text-base-content/60"

  defp tab_path(inv, "overview"), do: ~p"/invocation/#{inv.id}"
  defp tab_path(inv, tab), do: ~p"/invocation/#{inv.id}/#{tab}"

  defp file_uri(%{"uri" => uri}), do: uri
  defp file_uri(_), do: nil

  # --- render -------------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} current_path={@current_path}>
      <div class="flex flex-col gap-3">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link
                navigate={if @project, do: ~p"/p/#{@project.slug}", else: ~p"/"}
                class="hover:underline"
              >{if @project, do: @project.name, else: "All builds"}</.link>
              <span>/</span>
              <span class="font-mono" id="invocation-id" title="invocation id">{@invocation.id}</span>
            </div>
            <h1 class="mt-1 flex min-w-0 flex-wrap items-center gap-2">
              <.status_pill
                status={@invocation.status}
                exit_code_name={@invocation.exit_code_name}
                size="md"
              />
              <span class="truncate font-mono text-base font-semibold" id="command-line">{Format.command_line(
                @invocation
              )}</span>
            </h1>
            <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
              <span
                :if={@invocation.exit_code_name && @invocation.status != "succeeded"}
                class="font-medium text-base-content/90"
                id="exit-category"
              >
                {Status.category(@invocation.exit_code_name)}<span :if={@invocation.exit_code}> (exit {@invocation.exit_code})</span>
              </span>
              <span :if={@invocation.user_name}><.icon
                name="hero-user-micro"
                class="mr-0.5 inline size-3"
              />{@invocation.user_name}<span :if={@invocation.host}>@{@invocation.host}</span></span>
              <span :if={@invocation.workspace} class="font-mono" title="workspace">{@invocation.workspace}</span>
              <span :if={@invocation.bazel_version}>Bazel {@invocation.bazel_version}</span>
              <span :if={@invocation.started_at}>started
              <.relative_time id="header-started" at={@invocation.started_at} /></span>
            </div>
            <.tag_chips tags={@invocation.tags} max={12} class="mt-2" />
          </div>
          <div
            class="grid grid-cols-3 gap-x-6 gap-y-2 rounded-md border border-base-300 bg-base-200/40 px-4 py-2 text-sm sm:grid-cols-6"
            id="header-stats"
          >
            <.stat label="Duration"><.live_duration invocation={@invocation} /></.stat>
            <.stat label="Targets">
              <.counter
                ok={@invocation.targets_completed - @invocation.targets_failed}
                failed={@invocation.targets_failed}
              />
            </.stat>
            <.stat label="Tests">
              <span :if={@invocation.tests_total == 0} class="text-base-content/40">—</span>
              <.counter
                :if={@invocation.tests_total > 0}
                ok={@invocation.tests_passed}
                failed={@invocation.tests_failed + @invocation.tests_timed_out}
                extra={@invocation.tests_flaky}
              />
            </.stat>
            <.stat label="Actions">{Format.number(@invocation.actions_executed)}</.stat>
            <.stat label="Cache hits">{Format.cache_hit_rate(@invocation) || "—"}</.stat>
            <.stat label="Critical path">{Format.duration(@invocation.critical_path_ms)}</.stat>
          </div>
        </div>

        <nav
          class="flex gap-1 overflow-x-auto border-b border-base-300 text-sm"
          id="tabs"
          role="tablist"
        >
          <.link
            :for={tab <- @tabs}
            patch={tab_path(@invocation, tab)}
            role="tab"
            id={"tab-#{tab}"}
            aria-selected={to_string(@tab == tab)}
            class={[
              "-mb-px whitespace-nowrap border-b-2 px-3 py-2 capitalize transition-colors",
              @tab == tab && "border-primary font-medium text-base-content",
              @tab != tab && "border-transparent text-base-content/60 hover:text-base-content"
            ]}
          >
            {tab}
          </.link>
        </nav>

        <section id={"panel-#{@tab}"} role="tabpanel">
          <.overview
            :if={@tab == "overview"}
            invocation={@invocation}
            failed_targets={@failed_targets}
            slowest_tests={@slowest_tests}
            runner_counts={@runner_counts}
            mnemonics={@mnemonics}
          />
          <.log :if={@tab == "log"} invocation={@invocation} />
          <ConveyorWeb.Timeline.timeline
            :if={@tab == "timeline"}
            invocation={@invocation}
            tests={Map.values(@tests_by_key)}
            actions={@timeline_actions}
          />
          <.targets :if={@tab == "targets"} streams={@streams} count={map_size(@targets_by_key)} />
          <.tests :if={@tab == "tests"} groups={test_groups(@tests_by_key)} />
          <.actions
            :if={@tab == "actions"}
            streams={@streams}
            count={@action_count}
            invocation={@invocation}
          />
          <.metrics_tab :if={@tab == "metrics"} invocation={@invocation} metrics={@metrics} />
          <.details :if={@tab == "details"} artifacts={@artifacts} invocation={@invocation} />
          <.events
            :if={@tab == "events"}
            invocation={@invocation}
            events={@events}
            page={@events_page}
            pages={@events_pages}
            total={@events_total}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :invocation, :map, required: true
  attr :failed_targets, :list, required: true
  attr :slowest_tests, :list, required: true
  attr :runner_counts, :list, required: true
  attr :mnemonics, :list, required: true

  defp overview(assigns) do
    ~H"""
    <div class="grid gap-4 lg:grid-cols-3">
      <div class="space-y-4 lg:col-span-2">
        <div
          :if={@invocation.abort_description || @failed_targets != []}
          class="rounded-md border border-rose-500/30 bg-rose-500/5 p-4"
          id="failure-summary"
        >
          <h2 class="mb-2 text-sm font-semibold text-rose-700 dark:text-rose-300">What went wrong</h2>
          <p :if={@invocation.abort_reason} class="mb-2 text-sm">
            <span class="font-mono text-xs uppercase">{@invocation.abort_reason}</span>
          </p>
          <pre :if={@invocation.abort_description} class="mb-3 whitespace-pre-wrap font-mono text-xs">{@invocation.abort_description}</pre>
          <ul class="space-y-2">
            <li :for={t <- @failed_targets} class="text-sm">
              <div class="flex items-center gap-2">
                <span class={[
                  "font-mono text-xs font-semibold uppercase",
                  target_status_classes(t.status)
                ]}>{t.test_status || t.status}</span>
                <span class="font-mono text-[13px]">{t.label}</span>
                <span :if={t.kind} class="text-xs text-base-content/50">{t.kind}</span>
              </div>
              <pre
                :if={t.failure_message}
                class="mt-1 max-h-48 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2 font-mono text-xs"
              >{t.failure_message}</pre>
            </li>
          </ul>
        </div>

        <div class="rounded-md border border-base-300 p-4" id="phases">
          <h2 class="mb-3 text-sm font-semibold">Timing</h2>
          <div class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <.stat label="Wall">
              <.live_duration invocation={@invocation} id={"duration-wall-#{@invocation.id}"} />
            </.stat>
            <.stat label="Analysis">{Format.duration(@invocation.analysis_ms)}</.stat>
            <.stat label="Execution">{Format.duration(@invocation.execution_ms)}</.stat>
            <.stat label="Critical path">{Format.duration(@invocation.critical_path_ms)}</.stat>
            <.stat label="CPU time">{Format.duration(@invocation.cpu_ms)}</.stat>
            <.stat label="Packages loaded">{Format.number(@invocation.packages_loaded)}</.stat>
            <.stat label="Peak heap">{Format.bytes(@invocation.peak_heap_bytes)}</.stat>
            <.stat label="Network">
              {Format.bytes(@invocation.bytes_recv)} in / {Format.bytes(@invocation.bytes_sent)} out
            </.stat>
          </div>
          <.phase_bar invocation={@invocation} />
        </div>

        <div
          :if={@slowest_tests != []}
          class="rounded-md border border-base-300 p-4"
          id="slowest-tests"
        >
          <h2 class="mb-2 text-sm font-semibold">Slowest tests</h2>
          <table class="w-full text-sm">
            <tbody class="divide-y divide-base-300/60">
              <tr :for={t <- @slowest_tests}>
                <td class="py-1 font-mono text-[13px]">
                  {t.label}<span :if={t.shard > 1 or t.attempt > 1} class="text-base-content/50"> shard {t.shard} attempt {t.attempt}</span>
                </td>
                <td class={["py-1 text-right font-mono text-xs", test_status_classes(t.status)]}>
                  {t.status}
                </td>
                <td class="py-1 text-right font-mono text-xs tabular-nums">
                  {Format.duration(t.duration_ms)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="space-y-4">
        <div class="rounded-md border border-base-300 p-4" id="execution-summary">
          <h2 class="mb-3 text-sm font-semibold">Execution</h2>
          <dl class="space-y-1.5 text-sm">
            <div class="flex justify-between">
              <dt class="text-base-content/60">Actions created</dt><dd class="font-mono tabular-nums">
                {Format.number(@invocation.actions_created)}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Actions executed</dt><dd class="font-mono tabular-nums">
                {Format.number(@invocation.actions_executed)}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Remote cache hits</dt><dd class="font-mono tabular-nums">
                {Format.number(@invocation.remote_cache_hits)}
                <span class="text-base-content/50">({Format.cache_hit_rate(@invocation) || "—"})</span>
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">Action cache</dt><dd class="font-mono tabular-nums">
                {Format.number(@invocation.action_cache_hits)} hits / {Format.number(
                  @invocation.action_cache_misses
                )} misses
              </dd>
            </div>
            <div :for={{name, count} <- @runner_counts} class="flex justify-between">
              <dt class="text-base-content/60">{name}</dt><dd class="font-mono tabular-nums">
                {Format.number(count)}
              </dd>
            </div>
          </dl>
        </div>
        <div :if={@mnemonics != []} class="rounded-md border border-base-300 p-4" id="mnemonics">
          <h2 class="mb-2 text-sm font-semibold">Actions by mnemonic</h2>
          <table class="w-full text-sm">
            <tbody class="divide-y divide-base-300/60">
              <tr :for={{mnemonic, executed, created} <- @mnemonics}>
                <td class="py-1 font-mono text-xs">{mnemonic}</td>
                <td class="py-1 text-right font-mono text-xs tabular-nums" title="executed / created">
                  {Format.number(executed)}
                  <span class="text-base-content/40">/ {Format.number(created)}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :invocation, :map, required: true

  defp phase_bar(assigns) do
    total = assigns.invocation.wall_ms || assigns.invocation.duration_ms
    analysis = assigns.invocation.analysis_ms || 0
    execution = assigns.invocation.execution_ms || 0
    pct = fn part -> if total && total > 0, do: min(part * 100 / total, 100), else: 0 end

    assigns =
      assign(assigns, total: total, analysis_pct: pct.(analysis), execution_pct: pct.(execution))

    ~H"""
    <div
      :if={@total && @total > 0}
      class="mt-4"
      id="phase-bar"
      title="analysis vs execution share of wall time"
    >
      <div class="flex h-2 overflow-hidden rounded bg-base-300">
        <div class="bg-sky-500" style={"width: #{@analysis_pct}%"} title="analysis"></div>
        <div class="bg-emerald-500" style={"width: #{@execution_pct}%"} title="execution"></div>
      </div>
      <div class="mt-1 flex gap-4 text-[11px] text-base-content/60">
        <span><span class="mr-1 inline-block size-2 rounded-sm bg-sky-500"></span>analysis {Format.duration(
          @invocation.analysis_ms
        )}</span>
        <span><span class="mr-1 inline-block size-2 rounded-sm bg-emerald-500"></span>execution {Format.duration(
          @invocation.execution_ms
        )}</span>
      </div>
    </div>
    """
  end

  attr :invocation, :map, required: true

  defp log(assigns) do
    ~H"""
    <div
      id="log-viewer"
      phx-hook="LogViewer"
      phx-update="ignore"
      class="log-viewer flex flex-col rounded-md border border-base-300 bg-zinc-950 text-zinc-100 dark:bg-black"
    >
      <div class="flex flex-wrap items-center gap-2 border-b border-zinc-800 px-3 py-1.5 text-xs">
        <input
          type="search"
          data-log-search
          placeholder="Filter lines…"
          class="w-56 rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-xs text-zinc-100 placeholder:text-zinc-500"
        />
        <span data-log-status class="text-zinc-400"></span>
        <div class="ml-auto flex items-center gap-2">
          <button
            type="button"
            data-log-follow
            aria-pressed="false"
            class="rounded border border-zinc-700 px-2 py-1 text-xs hover:bg-zinc-800"
          >Follow</button>
          <a
            href={~p"/invocation/#{@invocation.id}/download/log"}
            class="rounded border border-zinc-700 px-2 py-1 text-xs hover:bg-zinc-800"
            id="download-log"
          >Download</a>
        </div>
      </div>
      <div
        data-log-viewport
        class="relative h-[70vh] overflow-auto font-mono text-[12px] leading-[18px]"
      >
        <div data-log-spacer class="relative">
          <div data-log-content class="absolute left-0 top-0 min-w-full px-2"></div>
        </div>
      </div>
    </div>
    """
  end

  attr :streams, :map, required: true
  attr :count, :integer, required: true

  defp targets(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-md border border-base-300">
      <table class="w-full text-sm">
        <thead class="bg-base-200/60 text-left text-[11px] uppercase tracking-wide text-base-content/60">
          <tr>
            <th class="px-3 py-2 font-medium">Status</th>
            <th class="px-3 py-2 font-medium">Label</th>
            <th class="px-3 py-2 font-medium">Kind</th>
            <th class="px-3 py-2 font-medium">Test</th>
            <th class="px-3 py-2 text-right font-medium">Duration</th>
          </tr>
        </thead>
        <tbody id="targets" phx-update="stream" class="divide-y divide-base-300/70">
          <tr id="targets-empty" class="hidden only:table-row">
            <td colspan="5">
              <.empty title="No targets yet" icon="hero-cube">
                Targets appear as Bazel configures and builds them.
              </.empty>
            </td>
          </tr>
          <tr
            :for={{dom_id, t} <- @streams.targets}
            id={dom_id}
            class="align-top"
            data-status={t.status}
          >
            <td class={[
              "px-3 py-1.5 font-mono text-xs font-semibold uppercase",
              target_status_classes(t.status)
            ]}>
              {t.status}
            </td>
            <td class="px-3 py-1.5 font-mono text-[13px]">
              {t.label}<span :if={t.aspect != ""} class="text-base-content/50"> ({t.aspect})</span>
              <pre
                :if={t.failure_message}
                class="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2 text-xs"
              >{t.failure_message}</pre>
            </td>
            <td class="px-3 py-1.5 text-xs text-base-content/70">{t.kind}</td>
            <td class={[
              "px-3 py-1.5 font-mono text-xs",
              test_status_classes(t.test_status || "NO_STATUS")
            ]}>
              {t.test_status}
            </td>
            <td class="px-3 py-1.5 text-right font-mono text-xs tabular-nums">
              {Format.duration(t.duration_ms)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :groups, :list, required: true

  defp tests(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-md border border-base-300">
      <table class="w-full text-sm" id="tests">
        <thead class="bg-base-200/60 text-left text-[11px] uppercase tracking-wide text-base-content/60">
          <tr>
            <th class="px-3 py-2 font-medium">Result</th>
            <th class="px-3 py-2 font-medium">Test</th>
            <th class="px-3 py-2 font-medium">Attempts</th>
            <th class="px-3 py-2 font-medium">Strategy</th>
            <th class="px-3 py-2 text-right font-medium">Duration</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-base-300/70">
          <tr :if={@groups == []}>
            <td colspan="5">
              <.empty title="No test results" icon="hero-beaker">
                Test attempts show up here as they finish.
              </.empty>
            </td>
          </tr>
          <tr
            :for={g <- @groups}
            id={"test-#{:erlang.phash2(g.label)}"}
            class="align-top"
            data-verdict={g.verdict}
          >
            <td class={["px-3 py-1.5 font-mono text-xs font-semibold", test_status_classes(g.verdict)]}>
              {g.verdict}
            </td>
            <td class="px-3 py-1.5 font-mono text-[13px]">{g.label}</td>
            <td class="px-3 py-1.5 text-xs">
              <div class="flex flex-wrap gap-1">
                <span
                  :for={a <- g.attempts}
                  class={[
                    "rounded border border-base-300 px-1.5 py-0.5 font-mono text-[11px]",
                    test_status_classes(a.status)
                  ]}
                  title={"run #{a.run} shard #{a.shard} attempt #{a.attempt}: #{a.status}#{if a.cached_locally or a.cached_remotely, do: " (cached)"}"}
                >
                  {if a.shard > 1 or length(g.attempts) > 1,
                    do: "s#{a.shard}/a#{a.attempt} ",
                    else: ""}{a.status}
                  <a
                    :if={
                      file_uri(Enum.find(List.wrap(a.files["files"]), &(&1["name"] == "test.log")))
                    }
                    href={file_uri(Enum.find(a.files["files"], &(&1["name"] == "test.log")))}
                    class="ml-1 text-base-content/50 hover:underline"
                    title="test.log (as reported by Bazel)"
                  >log</a>
                </span>
              </div>
            </td>
            <td class="px-3 py-1.5 text-xs text-base-content/70">
              {g.attempts
              |> Enum.map(& &1.strategy)
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq()
              |> Enum.join(", ")}<span :if={g.cached}> · cached</span>
            </td>
            <td class="px-3 py-1.5 text-right font-mono text-xs tabular-nums">
              {Format.duration(g.duration_ms)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :streams, :map, required: true
  attr :count, :integer, required: true
  attr :invocation, :map, required: true

  defp actions(assigns) do
    ~H"""
    <div>
      <p class="mb-2 text-xs text-base-content/60">
        Bazel reports failed actions by default; pass
        <code class="font-mono">--build_event_publish_all_actions</code>
        to see every action here.
      </p>
      <div class="overflow-x-auto rounded-md border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200/60 text-left text-[11px] uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2 font-medium">Result</th>
              <th class="px-3 py-2 font-medium">Mnemonic</th>
              <th class="px-3 py-2 font-medium">Target / output</th>
              <th class="px-3 py-2 text-right font-medium">Duration</th>
            </tr>
          </thead>
          <tbody id="actions" phx-update="stream" class="divide-y divide-base-300/70">
            <tr id="actions-empty" class="hidden only:table-row">
              <td colspan="4">
                <.empty title="No actions reported" icon="hero-bolt">
                  Nothing failed, and all-action publishing is off.
                </.empty>
              </td>
            </tr>
            <tr
              :for={{dom_id, a} <- @streams.actions}
              id={dom_id}
              class="align-top"
              data-success={to_string(a.success)}
            >
              <td class={[
                "px-3 py-1.5 font-mono text-xs font-semibold",
                (a.success && "text-emerald-600 dark:text-emerald-400") ||
                  "text-rose-600 dark:text-rose-400"
              ]}>
                {if a.success, do: "ok", else: "exit #{a.exit_code}"}
              </td>
              <td class="px-3 py-1.5 font-mono text-xs">{a.mnemonic}</td>
              <td class="px-3 py-1.5 font-mono text-[13px]">
                <div>{a.label}</div>
                <div
                  :if={a.primary_output}
                  class="truncate text-xs text-base-content/50"
                  title={a.primary_output}
                >
                  {a.primary_output}
                </div>
                <details :if={a.command_line != [] or a.failure_message} class="mt-1 text-xs">
                  <summary class="cursor-pointer text-base-content/60">details</summary>
                  <pre
                    :if={a.failure_message}
                    class="mt-1 whitespace-pre-wrap rounded bg-base-200 p-2"
                  >{a.failure_message}</pre>
                  <pre
                    :if={a.command_line != []}
                    class="mt-1 max-h-48 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2"
                  >{Enum.join(a.command_line, " ")}</pre>
                  <p :if={a.stderr_uri} class="mt-1 text-base-content/50">
                    stderr: <span class="font-mono">{a.stderr_uri}</span>
                  </p>
                </details>
              </td>
              <td class="px-3 py-1.5 text-right font-mono text-xs tabular-nums">
                {Format.duration(a.duration_ms)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :invocation, :map, required: true
  attr :metrics, :any, required: true

  defp metrics_tab(assigns) do
    groups = if assigns.metrics, do: Map.to_list(assigns.metrics.build_metrics), else: []
    logs = if assigns.metrics, do: assigns.metrics.tool_logs, else: %{}
    assigns = assign(assigns, groups: Enum.sort_by(groups, &elem(&1, 0)), logs: logs)

    ~H"""
    <div id="metrics" class="grid gap-4 lg:grid-cols-2">
      <p :if={@groups == []} class="text-sm text-base-content/60 lg:col-span-2">
        Bazel sends metrics at the end of a build; nothing has arrived yet.
      </p>
      <div
        :for={{name, value} <- @groups}
        class="rounded-md border border-base-300 p-4"
        id={"metrics-#{name}"}
      >
        <h2 class="mb-2 text-sm font-semibold">{humanize(name)}</h2>
        <.metric_value value={value} />
      </div>
      <div
        :if={@logs != %{}}
        class="rounded-md border border-base-300 p-4 lg:col-span-2"
        id="tool-logs"
      >
        <h2 class="mb-2 text-sm font-semibold">Build tool logs</h2>
        <dl class="space-y-2 text-xs">
          <div :for={{name, file} <- Enum.sort(@logs)}>
            <dt class="font-mono text-base-content/60">{name}</dt>
            <dd :if={file["contents"]}>
              <pre class="max-h-64 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-2 font-mono">{file["contents"]}</pre>
            </dd>
            <dd :if={file["uri"]} class="break-all font-mono">{file["uri"]}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  # Renders any BuildMetrics group: scalars as a definition list, lists of maps as tables,
  # nested maps recursively. New Bazel fields show up without code changes.
  attr :value, :any, required: true

  defp metric_value(%{value: value} = assigns) when is_map(value) do
    {scalars, nested} = Enum.split_with(value, fn {_, v} -> not is_map(v) and not is_list(v) end)
    assigns = assign(assigns, scalars: Enum.sort(scalars), nested: Enum.sort(nested))

    ~H"""
    <dl :if={@scalars != []} class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-0.5 text-xs">
      <%= for {k, v} <- @scalars do %>
        <dt class="text-base-content/60">{humanize(k)}</dt>
        <dd class="font-mono tabular-nums">{format_metric(k, v)}</dd>
      <% end %>
    </dl>
    <div :for={{k, v} <- @nested} class="mt-2">
      <h3 class="mb-1 text-[11px] font-medium uppercase tracking-wide text-base-content/60">
        {humanize(k)}
      </h3>
      <.metric_value value={v} />
    </div>
    """
  end

  defp metric_value(%{value: [first | _] = list} = assigns) when is_map(first) do
    columns =
      list
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.reject(fn c -> Enum.any?(list, &(is_map(&1[c]) or is_list(&1[c]))) end)

    assigns = assign(assigns, columns: columns, rows: list)

    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-xs">
        <thead>
          <tr>
            <th :for={c <- @columns} class="px-2 py-1 text-left font-medium text-base-content/60">
              {humanize(c)}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-base-300/60 font-mono tabular-nums">
          <tr :for={row <- @rows}>
            <td :for={c <- @columns} class="px-2 py-0.5">{format_metric(c, row[c])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp metric_value(assigns) do
    ~H"""
    <span class="font-mono text-xs">{inspect(@value)}</span>
    """
  end

  defp humanize(key) when is_binary(key) do
    key
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp format_metric(_k, nil), do: "—"

  defp format_metric(k, v) when is_binary(v),
    do:
      if(String.ends_with?(k, "Ms") and Integer.parse(v) != :error,
        do: Format.duration(String.to_integer(v)),
        else: v
      )

  defp format_metric(k, v) when is_integer(v),
    do: if(String.ends_with?(k, "Ms"), do: Format.duration(v), else: Format.number(v))

  defp format_metric(_k, v) when is_float(v), do: Float.to_string(v)
  defp format_metric(_k, v) when is_boolean(v), do: to_string(v)
  defp format_metric(_k, v), do: inspect(v)

  attr :invocation, :map, required: true
  attr :artifacts, :list, required: true

  defp details(assigns) do
    parsed = assigns.invocation.options["parsed"] || %{}

    assigns =
      assign(assigns,
        parsed: parsed,
        unstructured: assigns.invocation.options["unstructured"] || []
      )

    ~H"""
    <div class="grid gap-4 lg:grid-cols-2" id="details">
      <div class="rounded-md border border-base-300 p-4 lg:col-span-2">
        <h2 class="mb-2 text-sm font-semibold">Command line</h2>
        <pre
          class="max-h-64 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-3 font-mono text-xs"
          id="unstructured-command-line"
        >{Enum.join(@unstructured, " ")}</pre>
        <div class="mt-3 grid gap-3 sm:grid-cols-2">
          <div>
            <h3 class="mb-1 text-xs font-medium uppercase tracking-wide text-base-content/60">
              Explicit options
            </h3>
            <ul class="space-y-0.5 font-mono text-xs">
              <li :for={o <- List.wrap(@parsed["explicit_cmd_line"])}>{o}</li><li
                :if={@parsed["explicit_cmd_line"] in [nil, []]}
                class="text-base-content/50"
              >
                none
              </li>
            </ul>
          </div>
          <div>
            <h3 class="mb-1 text-xs font-medium uppercase tracking-wide text-base-content/60">
              Startup options
            </h3>
            <ul class="space-y-0.5 font-mono text-xs">
              <li :for={o <- List.wrap(@parsed["startup"])}>{o}</li><li
                :if={@parsed["startup"] in [nil, []]}
                class="text-base-content/50"
              >
                none
              </li>
            </ul>
          </div>
        </div>
      </div>
      <div class="rounded-md border border-base-300 p-4">
        <h2 class="mb-2 text-sm font-semibold">Environment</h2>
        <dl class="space-y-1 text-sm">
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Working dir</dt><dd class="break-all font-mono text-xs">
              {@invocation.cwd || "—"}
            </dd>
          </div>
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Workspace</dt><dd class="break-all font-mono text-xs">
              {@invocation.workspace || "—"}
            </dd>
          </div>
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Exec root</dt><dd class="break-all font-mono text-xs">
              {@invocation.local_exec_root || "—"}
            </dd>
          </div>
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Build id</dt><dd class="break-all font-mono text-xs">
              {@invocation.build_id || "—"}
            </dd>
          </div>
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Instance name</dt><dd class="font-mono text-xs">
              {@invocation.bes_instance_name || "—"}
            </dd>
          </div>
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Keywords</dt><dd class="font-mono text-xs">
              {Enum.join(@invocation.keywords, ", ")}
            </dd>
          </div>
          <div class="flex gap-3">
            <dt class="w-32 shrink-0 text-base-content/60">Profile</dt><dd class="break-all font-mono text-xs">
              <span id="profile-status">{@invocation.profile_status}</span>
              · {@invocation.profile_uri || "not reported"}
            </dd>
          </div>
        </dl>
      </div>
      <div class="rounded-md border border-base-300 p-4">
        <h2 class="mb-2 text-sm font-semibold">Artifacts</h2>
        <ul class="space-y-0.5 font-mono text-xs" id="artifacts">
          <li :for={a <- @artifacts} id={"artifact-#{a.id}"} class="flex gap-2">
            <a href={~p"/invocation/#{@invocation.id}/artifact/#{a.name}"} class="hover:underline">{a.name}</a>
            <span class="text-base-content/50">{Format.bytes(a.size)} · {a.source}</span>
          </li>
        </ul>
        <p :if={@artifacts == []} class="text-xs text-base-content/50">
          None. Upload with <code>tools/bes-upload-profile</code>
          or configure a cache endpoint in Settings.
        </p>
      </div>
      <div class="rounded-md border border-base-300 p-4">
        <h2 class="mb-2 text-sm font-semibold">Tags</h2>
        <dl class="space-y-0.5 font-mono text-xs" id="tags">
          <div :for={{k, v} <- Enum.sort(@invocation.tags)} class="flex gap-2">
            <dt class="text-base-content/50">{k}</dt><dd class="break-all">{v}</dd>
          </div>
        </dl>
        <h2 class="mb-2 mt-4 text-sm font-semibold">Workspace status</h2>
        <dl class="space-y-0.5 font-mono text-xs">
          <div :for={{k, v} <- Enum.sort(@invocation.workspace_status)} class="flex gap-2">
            <dt class="text-base-content/50">{k}</dt><dd class="break-all">{v}</dd>
          </div>
          <div :if={@invocation.workspace_status == %{}} class="text-base-content/50">none</div>
        </dl>
        <h2 class="mb-2 mt-4 text-sm font-semibold">Configurations</h2>
        <ul class="space-y-0.5 font-mono text-xs">
          <li :for={{id, c} <- @invocation.configurations}>
            {c["mnemonic"]}
            <span class="text-base-content/50">{c["platform"]} {c["cpu"]}{if c["is_tool"],
              do: " (tool)"} · {String.slice(id, 0, 12)}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :invocation, :map, required: true
  attr :events, :list, required: true
  attr :page, :integer, required: true
  attr :pages, :integer, required: true
  attr :total, :integer, required: true

  defp events(assigns) do
    ~H"""
    <div id="events">
      <div class="mb-2 flex flex-wrap items-center gap-3 text-xs text-base-content/60">
        <span>{@total} events · page {@page} of {@pages}</span>
        <.link
          :if={@page > 1}
          patch={~p"/invocation/#{@invocation.id}/events?page=#{@page - 1}"}
          class="rounded border border-base-300 px-2 py-0.5 hover:bg-base-200"
          id="events-prev"
        >Previous</.link>
        <.link
          :if={@page < @pages}
          patch={~p"/invocation/#{@invocation.id}/events?page=#{@page + 1}"}
          class="rounded border border-base-300 px-2 py-0.5 hover:bg-base-200"
          id="events-next"
        >Next</.link>
        <a
          href={~p"/invocation/#{@invocation.id}/download/events"}
          class="ml-auto rounded border border-base-300 px-2 py-0.5 hover:bg-base-200"
          id="download-events"
        >Download .bep</a>
      </div>
      <div class="divide-y divide-base-300/70 rounded-md border border-base-300">
        <details :for={e <- @events} id={"event-#{e.seq}"} class="group">
          <summary class="flex cursor-pointer items-center gap-3 px-3 py-1.5 text-sm hover:bg-base-200/50">
            <span class="w-12 font-mono text-xs text-base-content/50">#{e.seq}</span>
            <span class="font-mono text-xs">{e.kind}</span>
          </summary>
          <pre class="max-h-96 overflow-auto bg-base-200/60 p-3 font-mono text-[11px]">{e.json}</pre>
        </details>
        <p :if={@events == []} class="p-4 text-sm text-base-content/60">
          No events stored for this invocation.
        </p>
      </div>
    </div>
    """
  end
end
