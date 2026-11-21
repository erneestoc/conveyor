defmodule ConveyorWeb.RbeController do
  @moduledoc """
  The RBE opportunity report as JSON: the numbers of the page, for a project or a cache
  group in the browser session (`/p/:slug/rbe/json`, `/groups/:name/rbe/json`) and for
  the project of a `read`-scoped API key (`GET /api/v1/rbe?range=7d`). Times are
  milliseconds (`ms` wall, `core_ms` core time).
  """
  use ConveyorWeb, :controller

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
