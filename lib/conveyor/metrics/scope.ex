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
          from: DateTime.t(),
          to: DateTime.t(),
          query: Query.ast(),
          name: String.t() | nil
        }

  defstruct project_id: nil, from: nil, to: nil, query: [], name: nil

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
