defmodule Conveyor.Projects.Segments do
  @moduledoc """
  Segments are named saved queries used to split dashboards (Local vs CI, human vs AI…).
  Stored in `project.settings["segments"]`; these defaults apply until a project defines its own.
  """

  alias Conveyor.Projects.Project

  @defaults [%{"name" => "Local", "query" => "ci!=true"}, %{"name" => "CI", "query" => "ci:true"}]

  @spec defaults() :: [map()]
  def defaults, do: @defaults

  @spec for_project(Project.t() | nil) :: [map()]
  def for_project(%Project{settings: %{"segments" => segments}})
      when is_list(segments) and segments != [], do: segments

  def for_project(_), do: @defaults
end
