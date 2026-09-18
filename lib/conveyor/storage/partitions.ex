defmodule Conveyor.Storage.Partitions do
  @moduledoc """
  Maintains the daily range partitions of `event_segments` and `log_segments`.

  Partitions are keyed by the invocation's start day. `ensure/1` is idempotent and runs on
  boot and hourly (Oban cron) so partitions exist ahead of time; `drop_before/1` implements
  raw-data retention as cheap `DROP TABLE`s.
  """

  alias Conveyor.Repo

  @tables ~w(event_segments log_segments)

  @doc "Creates partitions from yesterday through `days_ahead` days in the future."
  @spec ensure(non_neg_integer(), Date.t()) :: :ok
  def ensure(days_ahead \\ 3, today \\ Date.utc_today()) do
    for offset <- -1..days_ahead, table <- @tables do
      day = Date.add(today, offset)
      create(table, day)
    end

    :ok
  end

  @doc "Creates the partition holding `day` for both tables (no-op if it exists)."
  @spec ensure_day(Date.t()) :: :ok
  def ensure_day(day) do
    Enum.each(@tables, &create(&1, day))
  end

  @doc "Drops every daily partition strictly older than `cutoff` and returns their names."
  @spec drop_before(Date.t()) :: [String.t()]
  def drop_before(cutoff) do
    for table <- @tables,
        name <- partition_names(table),
        day = day_of(table, name),
        Date.compare(day, cutoff) == :lt do
      Repo.query!("DROP TABLE IF EXISTS #{name}")
      name
    end
  end

  @doc "Lists the daily partitions of a table (excluding the default partition)."
  @spec partition_names(String.t()) :: [String.t()]
  def partition_names(table) when table in @tables do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = $1 AND c.relname <> $2
        ORDER BY c.relname
        """,
        [table, "#{table}_default"]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp create(table, day) do
    name = partition_name(table, day)
    from = Date.to_iso8601(day)
    to = Date.to_iso8601(Date.add(day, 1))

    # IF NOT EXISTS still raises when two nodes (or a boot task and a test helper) create
    # the same partition at the same moment; that outcome is fine.
    case Repo.query(
           "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{table} FOR VALUES FROM ('#{from}') TO ('#{to}')"
         ) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: code}}}
      when code in [:duplicate_table, :duplicate_object, :unique_violation] ->
        :ok

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def partition_name(table, day), do: "#{table}_#{Calendar.strftime(day, "%Y%m%d")}"

  defp day_of(table, name) do
    prefix = byte_size(table) + 1
    <<_::binary-size(^prefix), y::binary-4, m::binary-2, d::binary-2>> = name
    Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))
  end
end
