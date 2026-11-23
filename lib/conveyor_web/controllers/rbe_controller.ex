defmodule ConveyorWeb.RbeController do
  @moduledoc """
  The duplicate-work report as JSON: the numbers of the page, for a project or a cache
  group in the browser session (`/p/:slug/duplicate-work/json`,
  `/groups/:name/duplicate-work/json`) and for the project of a `read`-scoped API key
  (`GET /api/v1/duplicate-work?range=7d`). Times are milliseconds (`ms` wall, `core_ms`
  core time).

  The feature was named "RBE opportunity" and lived under `/rbe`: the old JSON paths and
  `GET /api/v1/rbe` are routed to the same actions, and the old page paths redirect to
  the new ones with their query string (`moved_project/2`, `moved_group/2`).
  """
  use ConveyorWeb, :controller

  alias Conveyor.Accounts.Scope, as: Viewer
  alias Conveyor.Rbe.{Groups, Report}
  alias ConveyorWeb.RbeReport

  def project(conn, %{"slug" => slug} = params) do
    viewer = conn.assigns.current_scope

    project =
      ConveyorWeb.Auth.visible_project_by_slug(viewer, slug) ||
        raise ConveyorWeb.NotFoundError, "no project #{slug}"

    respond(conn, params, &RbeReport.project(viewer, project, &1))
  end

  def group(conn, %{"name" => name} = params) do
    viewer = conn.assigns.current_scope

    with %Groups{} = group <- Groups.get_by_name(name),
         range = RbeReport.range(params["range"]),
         %{} = report <- RbeReport.group(viewer, group, range) do
      json(conn, %{range: range, report: Report.to_json(report)})
    else
      _ -> raise ConveyorWeb.NotFoundError, "no cache group #{name}"
    end
  end

  def moved_project(conn, %{"slug" => slug}) do
    project =
      ConveyorWeb.Auth.visible_project_by_slug(conn.assigns.current_scope, slug) ||
        raise ConveyorWeb.NotFoundError, "no project #{slug}"

    moved(conn, ~p"/p/#{project.slug}/duplicate-work")
  end

  def moved_group(conn, %{"name" => name}) do
    group = Groups.get_by_name(name)

    if is_nil(group) or
         Viewer.visible_projects(conn.assigns.current_scope, Groups.members(group)) == [],
       do: raise(ConveyorWeb.NotFoundError, "no cache group #{name}")

    moved(conn, ~p"/groups/#{group.name}/duplicate-work")
  end

  defp moved(conn, path) do
    to = if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string
    conn |> put_status(:moved_permanently) |> redirect(to: to)
  end

  # A key reads its own project; other projects of its group appear without names.
  def api(conn, params) do
    project = Conveyor.Projects.get_project!(conn.assigns.api_key.project_id)

    respond(conn, params, fn range ->
      scope = range |> Conveyor.Metrics.Scope.new(project.id) |> Conveyor.Metrics.Rollup.ensure!()

      Report.build(scope,
        settings: Conveyor.Rbe.Settings.get(project),
        visible: [project.id],
        names: %{project.id => project.name}
      )
    end)
  end

  defp respond(conn, params, build) do
    range = RbeReport.range(params["range"])
    json(conn, %{range: range, report: Report.to_json(build.(range))})
  end
end
