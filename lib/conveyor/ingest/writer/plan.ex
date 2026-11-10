defmodule Conveyor.Ingest.Writer.Plan do
  @moduledoc """
  What a group of units writes: the segment rows of each unit (compressed here, once per
  group) and the rows of every other table, merged across the units of an attempt. No
  database and no process; the only state is the compression contexts a shard keeps.
  """

  alias Conveyor.Ingest.Batch
  alias Conveyor.Invocations

  @type segments :: {event_row :: map() | nil, log_row :: map() | nil}
  @type compressors :: %{bep: (iodata() -> binary()), text: (iodata() -> binary())}

  @type t :: %{
          event_rows: [map()],
          log_rows: [map()],
          targets: [map()],
          tests: [map()],
          actions: [map()],
          metrics: [map()],
          tag_counts: %{{term(), String.t(), String.t()} => pos_integer()}
        }

  @doc """
  Compressors for the calling process, to keep for its lifetime: one zstd context for raw
  events (with the BEP dictionary) and one for log text, reused for every segment instead
  of created per call. The frames are the ones `Invocations.compress_bep/1` and
  `compress/1` produce, so every reader decodes them. A context belongs to the process
  that made it.
  """
  @spec compressors() :: compressors()
  defdelegate compressors, to: Invocations

  @doc "The segment rows of a unit, compressed: `{event row | nil, log row | nil}`."
  @spec segments(Batch.t(), compressors()) :: segments()
  def segments(%Batch{} = unit, %{bep: bep, text: text}),
    do: {Batch.event_segment_row(unit, bep), Batch.log_segment_row(unit, text)}

  @doc """
  The rows every table receives for the units of one attempt: their segment rows as given
  (made by `segments/2`, and in blob mode laid out by `Writer.Store`), everything else
  merged across the units in order.
  """
  @spec rows([Batch.t()], [segments()]) :: t()
  def rows(units, segments) do
    now = DateTime.utc_now()

    %{
      event_rows: for({row, _} <- segments, row != nil, do: row),
      log_rows: for({_, row} <- segments, row != nil, do: row),
      targets: merged_rows(units, :targets),
      tests: merged_rows(units, :tests),
      actions: flat_rows(units, :actions),
      metrics: metrics_rows(units, now),
      tag_counts: tag_counts(units)
    }
  end

  # Keyed rows (targets, tests) merged per invocation and key, later batches over earlier
  # ones: one upsert must not touch the same row twice, and the result must equal applying
  # the batches in order.
  defp merged_rows(batches, field) do
    batches
    |> Enum.reduce(%{}, fn b, acc ->
      Enum.reduce(Map.fetch!(b, field), acc, fn {key, attrs}, acc ->
        Map.update(
          acc,
          {b.invocation_id, key},
          Map.put(attrs, :invocation_id, b.invocation_id),
          &Map.merge(&1, attrs)
        )
      end)
    end)
    |> Map.values()
  end

  defp flat_rows(batches, field) do
    Enum.flat_map(batches, fn b ->
      b
      |> Map.fetch!(field)
      |> Enum.reverse()
      |> Enum.map(&Map.put(&1, :invocation_id, b.invocation_id))
    end)
  end

  defp metrics_rows(batches, now) do
    batches
    |> Enum.reduce(%{}, fn
      %{metrics: nil}, acc -> acc
      b, acc -> Map.update(acc, b.invocation_id, b.metrics, &Map.merge(&1, b.metrics))
    end)
    |> Enum.map(fn {id, metrics} ->
      Map.merge(metrics, %{invocation_id: id, inserted_at: now, updated_at: now})
    end)
  end

  # Counts per (project, key, value) across the group, for the TagCounter.
  defp tag_counts(batches) do
    Enum.reduce(batches, %{}, fn b, acc ->
      Enum.reduce(b.tag_keys, acc, fn {{k, v}, n}, acc ->
        Map.update(acc, {b.project_id, k, v}, n, &(&1 + n))
      end)
    end)
  end
end
