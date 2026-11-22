defmodule Conveyor.Rbe.Reread do
  @moduledoc """
  Parses stored execution logs again, so a changed cores declaration
  (`Conveyor.Rbe.Settings`, `cores_property`) reaches builds parsed before the change.

  The cores an exec property states are stored per spawn when its log is parsed, and a
  spawn's platform properties are not stored: the uploaded log is the only place to read
  them again. `Conveyor.Workers.ParseExecLog` replaces a build's spawns in one
  transaction and merges the same action keys to the same rows (PLAN §27.3), so running
  it again on an unchanged log changes the cores and nothing else; the build's hours are
  then summarized again.

  Bounds: only builds of the project that started in the window, whose log is parsed
  (an expired build's spawns are not brought back) and still attached; the #{200} most
  recent of them per request; jobs go to the `parse` queue behind fresh uploads
  (priority 3 against 0) and are unique per build for a minute, so a second request
  right after the first adds nothing.
  """
  import Ecto.Query

  alias Conveyor.Invocations
  alias Conveyor.Invocations.{Artifact, Invocation}
  alias Conveyor.Projects.Project
  alias Conveyor.Repo
  alias Conveyor.Workers.ParseExecLog

  @max 200
  @priority 3

  @doc "The most builds one request parses again."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc "How many builds a request would parse again (at most `max/0`)."
  @spec count(Project.t(), DateTime.t()) :: non_neg_integer()
  def count(%Project{} = project, %DateTime{} = from),
    do: project |> candidates(from) |> subquery() |> Repo.aggregate(:count)

  @doc "Enqueues the parse of the window's most recent builds with a stored log. Returns how many."
  @spec enqueue!(Project.t(), DateTime.t()) :: non_neg_integer()
  def enqueue!(%Project{} = project, %DateTime{} = from) do
    builds = Repo.all(candidates(project, from))

    Enum.each(builds, fn inv ->
      inv |> Invocations.job_args() |> ParseExecLog.new(priority: @priority) |> Oban.insert!()
    end)

    length(builds)
  end

  # The same test of a name as `Conveyor.ExecLog.name?/1`.
  defp candidates(%Project{id: project_id}, from) do
    logs =
      from a in Artifact,
        where: a.invocation_id == parent_as(:build).id,
        where: fragment("? ~* ?", a.name, "exec(ution)?[._-]?log")

    from i in Invocation,
      as: :build,
      where: i.project_id == ^project_id and i.exec_log_status == "parsed",
      where: i.started_at >= ^from,
      where: exists(logs),
      order_by: [desc: i.started_at],
      limit: @max
  end
end
