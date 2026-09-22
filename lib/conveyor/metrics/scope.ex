defmodule Conveyor.Metrics.Scope do
  @moduledoc """
  What a dashboard looks at: an optional project, a time window over `started_at`, and an
  optional search query (the same language as the builds list). Segments are scopes with
  an extra query appended.
  """
  import Ecto.Query

  alias Conveyor.Invocations.Invocation
  alias Conveyor.Query

  @type t :: %__MODULE__{
          project_id: integer() | nil,
          project_ids: :all | [integer()],
          from: DateTime.t(),
          to: DateTime.t(),
          query: Query.ast(),
          name: String.t() | nil
        }

  defstruct project_id: nil,
            project_ids: :all,
            from: nil,
            to: nil,
            query: [],
            name: nil,
            # set by Conveyor.Metrics.Rollup.ensure!/1 once a page has verified the window
            rolled: false

  @ranges %{"24h" => 24 * 3600, "7d" => 7 * 86_400, "30d" => 30 * 86_400, "90d" => 90 * 86_400}

  def ranges, do: ["24h", "7d", "30d", "90d"]

  @doc "Builds a scope from a range key (`24h`, `7d`, `30d`, `90d`), a project id and a query."
  @spec new(String.t(), integer() | nil, Query.ast(), DateTime.t()) :: t()
  def new(range, project_id, query \\ [], now \\ DateTime.utc_now()) do
    seconds = Map.get(@ranges, range, @ranges["7d"])

    %__MODULE__{
      project_id: project_id,
      from: DateTime.add(now, -seconds, :second),
      to: now,
      query: query
    }
  end

  @doc """
  Restricts the scope to the projects a viewer may read (`Conveyor.Accounts.Scope.project_ids/1`).
  An all-projects dashboard is only ever "all the projects this viewer may see".
  """
  @spec restrict(t(), :all | [integer()]) :: t()
  def restrict(%__MODULE__{} = scope, project_ids), do: %{scope | project_ids: project_ids}

  @doc "The window of the same length immediately before this one (for period-over-period deltas)."
  @spec previous(t()) :: t()
  def previous(%__MODULE__{from: from, to: to} = scope) do
    length = DateTime.diff(to, from, :microsecond)
    %{scope | from: DateTime.add(from, -length, :microsecond), to: from}
  end

  @doc "Returns one scope per segment, each with the segment's query added."
  @spec segments(t(), [map()]) :: [t()]
  def segments(%__MODULE__{} = scope, segments) do
    Enum.map(segments, fn %{"name" => name, "query" => q} ->
      %{scope | name: name, query: scope.query ++ Query.parse!(q)}
    end)
  end

  @doc "The bucket size that keeps a series readable for this window."
  @spec bucket(t()) :: :hour | :day
  def bucket(%__MODULE__{from: from, to: to}) do
    if DateTime.diff(to, from, :hour) <= 48, do: :hour, else: :day
  end

  @doc "Base query: invocations inside the scope (all statuses)."
  @spec base(t()) :: Ecto.Query.t()
  def base(%__MODULE__{} = scope) do
    Invocation
    |> where([i], i.started_at >= ^scope.from and i.started_at < ^scope.to)
    |> maybe_project(scope.project_id)
    |> Conveyor.Invocations.maybe_projects(scope.project_ids)
    |> maybe_query(scope.query)
  end

  @doc "Base query restricted to finished builds (the ones with a verdict and a duration)."
  @spec finished(t()) :: Ecto.Query.t()
  def finished(scope),
    do: scope |> base() |> where([i], i.status in ["succeeded", "failed", "aborted"])

  defp maybe_project(query, nil), do: query
  defp maybe_project(query, id), do: where(query, [i], i.project_id == ^id)

  defp maybe_query(query, []), do: query
  defp maybe_query(query, ast), do: where(query, ^Query.to_dynamic(ast))
end
