defmodule Conveyor.Rbe.Stream do
  @moduledoc """
  Duplicate work from the event stream alone (PLAN §28): what is read back from the
  chunks the ingest path wrote for a build with `--build_event_publish_all_actions`.
  """
  import Ecto.Query

  alias Conveyor.Rbe.{StreamActions, StreamChunk}
  alias Conveyor.Repo

  @commit_tags ~w(commit commit_sha git_commit build_scm_revision stable_git_commit)

  @doc "The per-action records of a build, in stream order."
  @spec records(String.t()) :: [StreamActions.action()]
  def records(invocation_id) do
    from(c in StreamChunk,
      where: c.invocation_id == ^invocation_id,
      order_by: c.first_seq,
      select: c.records
    )
    |> Repo.all()
    |> Enum.flat_map(&StreamActions.decode/1)
  end

  @doc """
  The commit a build ran at, from the tags Conveyor already keeps (`--build_metadata`,
  workspace status, keywords, API key tags): `commit`, else the usual names of a
  workspace status command. Nil when the build names none: then it has no same-commit
  figure.
  """
  @spec commit(map() | nil) :: String.t() | nil
  def commit(tags) when is_map(tags), do: Enum.find_value(@commit_tags, &tags[&1])
  def commit(_), do: nil
end
