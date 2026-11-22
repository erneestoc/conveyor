defmodule Conveyor.ExecLog.Properties do
  @moduledoc """
  Which exec (platform) property names a project's execution logs carry, so its admin can
  pick the one that states cores (`Conveyor.Rbe.Settings`, `cores_property`) without
  guessing.

  Nothing is kept per spawn. A parse counts, per property name, the spawns of the log
  that carry it and keeps one example value (`observe/2`, `summary/1`); the store then
  upserts one row per name into `exec_properties` (`record!/3`):

    * `spawns` is the count of **the log that last refreshed the row**, not a running
      total, so parsing a log again changes nothing;
    * a row is refreshed at most every ten minutes, so the parsers of a busy project do
      not rewrite the same rows for every log; names are written in sorted order;
    * at most #{50} names per log (the most frequent) and #{100} per project (the most
      recently seen); names longer than 64 bytes or not printable are skipped;
    * an example value is kept only when it is short and plain (`^[\\w.:/+-]{1,40}$`) and
      neither the name nor the value looks like a credential to `Conveyor.Ingest.Scrub`
      (`token`, `secret`, `key`, `auth`, a URL…). Otherwise the name is listed without
      an example.

  Rows leave with their project.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Conveyor.Ingest.Scrub
  alias Conveyor.Repo

  @per_log 50
  @per_project 100
  @refresh_s 600
  @name_re ~r/^[\x21-\x7e]{1,64}$/
  @value_re ~r/^[\w.:\/+-]{1,40}$/

  @type t :: %__MODULE__{}
  @typedoc "What a parse saw of one name: spawns carrying it, one example value or nil."
  @type seen :: %{name: String.t(), spawns: pos_integer(), sample: String.t() | nil}

  @primary_key false
  schema "exec_properties" do
    field :project_id, :integer, primary_key: true
    field :name, :string, primary_key: true
    field :spawns, :integer
    field :sample, :string
    field :last_seen_at, :utc_datetime_usec
  end

  @doc "Adds a spawn's platform to a parse's tally (`name → {spawns, sample}`)."
  @spec observe(map(), struct() | nil) :: map()
  def observe(tally, nil), do: tally

  def observe(tally, %{properties: properties}) do
    properties
    |> Enum.uniq_by(& &1.name)
    |> Enum.reduce(tally, fn %{name: name, value: value}, tally ->
      case tally do
        %{^name => {n, nil}} -> Map.put(tally, name, {n + 1, sample(name, value)})
        %{^name => {n, sample}} -> Map.put(tally, name, {n + 1, sample})
        _ -> Map.put(tally, name, {1, sample(name, value)})
      end
    end)
  end

  @doc "The tally of a log as a list: its most frequent names, capped."
  @spec summary(map()) :: [seen()]
  def summary(tally) do
    tally
    |> Enum.filter(fn {name, _} -> Regex.match?(@name_re, name) end)
    |> Enum.sort_by(fn {name, {n, _}} -> {-n, name} end)
    |> Enum.take(@per_log)
    |> Enum.map(fn {name, {n, sample}} -> %{name: name, spawns: n, sample: sample} end)
  end

  @doc "An example value that may be stored, or nil."
  @spec sample(String.t(), String.t()) :: String.t() | nil
  def sample(name, value) do
    value = String.trim(value)

    if Regex.match?(@value_re, value) and not Scrub.candidate?(name <> "=" <> value),
      do: value
  end

  @doc """
  Records what a parsed log carried. One statement, names in sorted order, outside the
  transaction that stores the spawns; a row seen less than ten minutes ago is left alone.
  """
  @spec record!(integer(), [seen()], DateTime.t()) :: :ok
  def record!(project_id, seen, now \\ DateTime.utc_now())
  def record!(_project_id, [], _now), do: :ok

  def record!(project_id, seen, now) do
    rows =
      seen
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&Map.merge(&1, %{project_id: project_id, last_seen_at: now}))

    stale = DateTime.add(now, -@refresh_s, :second)

    Repo.insert_all(__MODULE__, rows,
      conflict_target: [:project_id, :name],
      on_conflict:
        from(p in __MODULE__,
          where: p.last_seen_at < ^stale,
          update: [
            set: [
              spawns: fragment("EXCLUDED.spawns"),
              sample: fragment("coalesce(EXCLUDED.sample, ?)", p.sample),
              last_seen_at: fragment("EXCLUDED.last_seen_at")
            ]
          ]
        )
    )

    if Repo.aggregate(of(project_id), :count) > @per_project, do: prune!(project_id)
    :ok
  end

  defp prune!(project_id) do
    keep = from(p in ranked(project_id), limit: @per_project, select: p.name)

    Repo.delete_all(from p in of(project_id), where: p.name not in subquery(keep))
  end

  @doc "The names seen in a project's logs: the most recently seen first, then by spawns."
  @spec list(integer(), pos_integer()) :: [t()]
  def list(project_id, limit \\ 10), do: Repo.all(from p in ranked(project_id), limit: ^limit)

  defp of(project_id), do: from(p in __MODULE__, where: p.project_id == ^project_id)

  # By the hour a name was last seen (rows of one log share a stamp; logs of one hour
  # rank together), then by how many spawns carried it.
  defp ranked(project_id) do
    from p in of(project_id),
      order_by: [
        desc: fragment("date_trunc('hour', ?)", p.last_seen_at),
        desc: p.spawns,
        asc: p.name
      ]
  end
end
