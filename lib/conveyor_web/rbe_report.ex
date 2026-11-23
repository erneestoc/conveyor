defmodule ConveyorWeb.RbeReport do
  @moduledoc """
  Loads the duplicate-work report for a viewer: a project's, or a cache group's (the sum
  over its projects). The page and the JSON endpoints share it, so both apply the same
  visibility: a group is visible to whoever may see one of its projects, and the names
  and targets of the others never leave `Conveyor.Rbe.Report`.
  """
  alias Conveyor.Accounts.Scope, as: Viewer
  alias Conveyor.Metrics.{Rollup, Scope}
  alias Conveyor.Projects.Project
  alias Conveyor.Rbe.{Groups, Report, Settings}

  # What the report reads of an hour.
  @fields [:builds, :succeeded, :failed, :aborted, :fleet, :rbe]

  @spec ranges() :: [String.t()]
  def ranges, do: Scope.ranges()

  @spec range(String.t() | nil) :: String.t()
  def range(range), do: if(range in Scope.ranges(), do: range, else: "7d")

  @doc "The report of one project."
  @spec project(Viewer.t(), Project.t(), String.t()) :: map()
  def project(viewer, %Project{} = project, range) do
    scope = Rollup.ensure!(%{Scope.new(range, project.id) | rollup_fields: @fields})
    related = [project | Groups.members(Groups.of(project))]
    Report.build(scope, [settings: Settings.get(project)] ++ visibility(viewer, related))
  end

  @doc "The report of a group, or nil when the viewer may see none of its projects."
  @spec group(Viewer.t(), Groups.t(), String.t()) :: map() | nil
  def group(viewer, %Groups{} = group, range) do
    members = Groups.members(group)

    case Viewer.visible_projects(viewer, members) do
      [] ->
        nil

      [first | _] = seen ->
        # A group's window starts on the hour and is read from stored hours alone
        # (`Scope` `stored`): nothing is computed over every member at once.
        scope = range |> Scope.new(nil) |> Scope.restrict(Enum.map(members, & &1.id))

        scope =
          Rollup.ensure!(%{
            scope
            | stored: true,
              from: Rollup.truncate(scope.from, :hour),
              rollup_fields: @fields
          })

        # One cores setting for a sum over projects: the members' settings merged, the
        # first project to name a mnemonic wins.
        cores =
          seen
          |> Enum.reverse()
          |> Enum.map(&Settings.get(&1).cores)
          |> Enum.reduce(%{}, &Map.merge(&2, &1))

        report =
          Report.build(
            scope,
            [settings: %{Settings.get(first) | cores: cores}] ++ visibility(viewer, members)
          )

        Map.put(report, :members, length(members))
    end
  end

  defp visibility(viewer, projects) do
    seen = Viewer.visible_projects(viewer, projects)
    [visible: Enum.map(seen, & &1.id), names: Map.new(seen, &{&1.id, &1.name})]
  end
end
