defmodule ConveyorWeb.BuildsLive do
  @moduledoc "The builds list: newest first, live-updating, filterable by status and project."
  use ConveyorWeb, :live_view

  import ConveyorWeb.BuildComponents

  alias Conveyor.Ingest
  alias Conveyor.Invocations
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Projects
  alias ConveyorWeb.Format

  @page_size 50
  @status_filters %{
    "all" => nil,
    "running" => ["in_progress"],
    "succeeded" => ["succeeded"],
    "failed" => ["failed", "aborted", "disconnected", "unknown"]
  }

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
      topic = if project, do: Ingest.project_topic(project.id), else: Ingest.all_topic()
      Phoenix.PubSub.subscribe(Conveyor.PubSub, topic)
    end

    {:ok,
     socket
     |> assign(
       projects: projects,
       project: project,
       page_title: if(project, do: "#{project.name} builds", else: "Builds")
     )
     |> assign(status_filter: "all", known: MapSet.new(), has_more: false, cursor: nil, count: 0)
     |> stream_configure(:invocations, dom_id: &"inv-#{&1.id}")
     |> stream(:invocations, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filter = if Map.has_key?(@status_filters, params["status"]), do: params["status"], else: "all"
    rows = load(socket.assigns.project, filter, nil)

    {:noreply,
     socket
     |> assign(status_filter: filter, current_path: URI.parse(uri).path)
     |> assign(
       known: MapSet.new(rows, & &1.id),
       has_more: length(rows) == @page_size,
       cursor: cursor(rows),
       count: length(rows)
     )
     |> stream(:invocations, rows, reset: true)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    rows = load(socket.assigns.project, socket.assigns.status_filter, socket.assigns.cursor)

    {:noreply,
     socket
     |> assign(known: Enum.reduce(rows, socket.assigns.known, &MapSet.put(&2, &1.id)))
     |> assign(
       has_more: length(rows) == @page_size,
       cursor: cursor(rows) || socket.assigns.cursor,
       count: socket.assigns.count + length(rows)
     )
     |> stream(:invocations, rows)}
  end

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns.project, status))}
  end

  @impl true
  def handle_info({:invocation_updated, summary}, socket) do
    inv = to_invocation(summary)
    matches? = matches_filter?(inv, socket.assigns.status_filter)
    known? = MapSet.member?(socket.assigns.known, inv.id)

    cond do
      matches? and known? ->
        {:noreply, stream_insert(socket, :invocations, inv)}

      matches? ->
        {:noreply,
         socket
         |> assign(
           known: MapSet.put(socket.assigns.known, inv.id),
           count: socket.assigns.count + 1
         )
         |> stream_insert(:invocations, inv, at: 0)}

      known? ->
        {:noreply,
         socket
         |> assign(
           known: MapSet.delete(socket.assigns.known, inv.id),
           count: max(socket.assigns.count - 1, 0)
         )
         |> stream_delete(:invocations, inv)}

      true ->
        {:noreply, socket}
    end
  end

  defp load(project, filter, cursor) do
    Invocations.list(
      project_id: project && project.id,
      statuses: @status_filters[filter],
      limit: @page_size,
      before: cursor
    )
  end

  defp cursor([]), do: nil

  defp cursor(rows) do
    last = List.last(rows)
    {last.started_at, last.id}
  end

  defp matches_filter?(_inv, "all"), do: true
  defp matches_filter?(inv, filter), do: inv.status in @status_filters[filter]

  # Ingest digests are plain maps with the invocation's columns; the list renders structs.
  defp to_invocation(summary) do
    struct(Invocation, Map.take(summary, Invocation.__schema__(:fields)))
  end

  defp list_path(nil, "all"), do: ~p"/"
  defp list_path(nil, status), do: ~p"/?status=#{status}"
  defp list_path(project, "all"), do: ~p"/p/#{project.slug}"
  defp list_path(project, status), do: ~p"/p/#{project.slug}?status=#{status}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} projects={@projects} project={@project} current_path={@current_path}>
      <div class="flex flex-wrap items-center justify-between gap-3 pb-3">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">
            {if @project, do: @project.name, else: "All builds"}
          </h1>
          <p class="text-xs text-base-content/60">
            Newest first · updates live as Bazel streams events
          </p>
        </div>
        <div
          class="flex items-center gap-1 rounded-md border border-base-300 p-0.5 text-xs"
          id="status-filter"
          role="tablist"
        >
          <button
            :for={
              {key, label} <- [
                {"all", "All"},
                {"running", "Running"},
                {"succeeded", "Succeeded"},
                {"failed", "Failed"}
              ]
            }
            type="button"
            role="tab"
            id={"filter-#{key}"}
            phx-click="filter"
            phx-value-status={key}
            aria-selected={to_string(@status_filter == key)}
            class={[
              "rounded px-2.5 py-1 transition-colors",
              @status_filter == key && "bg-base-content text-base-100",
              @status_filter != key && "text-base-content/70 hover:bg-base-200"
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div class="overflow-x-auto rounded-md border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200/60 text-left text-[11px] uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2 font-medium">Status</th>
              <th class="px-3 py-2 font-medium">Build</th>
              <th class="px-3 py-2 font-medium">Targets</th>
              <th class="px-3 py-2 font-medium">Tests</th>
              <th class="px-3 py-2 font-medium">Cache</th>
              <th class="px-3 py-2 text-right font-medium">Duration</th>
              <th class="px-3 py-2 text-right font-medium">Started</th>
            </tr>
          </thead>
          <tbody id="invocations" phx-update="stream" class="divide-y divide-base-300/70">
            <tr id="invocations-empty" class="hidden only:table-row">
              <td colspan="7">
                <.empty title="No builds yet">
                  Point Bazel at this server with <code class="font-mono">--bes_backend</code>
                  and builds will appear here as they run.
                </.empty>
              </td>
            </tr>
            <tr
              :for={{dom_id, inv} <- @streams.invocations}
              id={dom_id}
              class="cursor-pointer align-top transition-colors hover:bg-base-200/50"
              phx-click={JS.navigate(~p"/invocation/#{inv.id}")}
              data-status={inv.status}
            >
              <td class="px-3 py-2">
                <.status_pill status={inv.status} exit_code_name={inv.exit_code_name} />
              </td>
              <td class="max-w-xl px-3 py-2">
                <.link
                  navigate={~p"/invocation/#{inv.id}"}
                  class="block truncate font-mono text-[13px] font-medium hover:underline"
                  title={Format.command_line(inv)}
                >
                  {Format.command_line(inv)}
                </.link>
                <div class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
                  <span :if={inv.user_name}>{inv.user_name}<span :if={inv.host}>@{inv.host}</span></span>
                  <span
                    :if={inv.exit_code_name && inv.status != "succeeded"}
                    class="text-base-content/80"
                  >{Conveyor.Ingest.Status.category(inv.exit_code_name)}</span>
                  <.tag_chips tags={inv.tags} />
                </div>
              </td>
              <td class="px-3 py-2">
                <.counter
                  ok={inv.targets_completed - inv.targets_failed}
                  failed={inv.targets_failed}
                  title="targets built / failed"
                />
              </td>
              <td class="px-3 py-2">
                <span :if={inv.tests_total == 0} class="text-xs text-base-content/40">—</span>
                <.counter
                  :if={inv.tests_total > 0}
                  ok={inv.tests_passed}
                  failed={inv.tests_failed + inv.tests_timed_out}
                  extra={inv.tests_flaky}
                  title="tests passed / failed / flaky"
                />
              </td>
              <td class="px-3 py-2 font-mono text-xs tabular-nums">
                {Format.cache_hit_rate(inv) || "—"}
              </td>
              <td class="px-3 py-2 text-right font-mono text-xs">
                <.live_duration invocation={inv} />
              </td>
              <td class="px-3 py-2 text-right text-xs text-base-content/60">
                <.relative_time id={"started-#{inv.id}"} at={inv.started_at} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@has_more} class="flex justify-center py-4">
        <button
          type="button"
          id="load-more"
          phx-click="load_more"
          class="rounded-md border border-base-300 px-3 py-1.5 text-sm hover:bg-base-200"
        >
          Load more
        </button>
      </div>
    </Layouts.app>
    """
  end
end
