defmodule Conveyor.RawLog do
  @moduledoc """
  The raw log (PLAN §25 step 2): in blob mode a writer shard puts each group commit's
  compressed payloads into one object here, and the segment rows in Postgres carry a byte
  range of it instead of the bytes. Objects are server-internal (never served by URL,
  read by range through the server), span projects, and are time-ordered by key under
  `rawlog/<node>/<shard>/<ulid>` in the same backend as the blob store (`BLOB_STORE`),
  through the same adapter (`Conveyor.Blobs.Adapter`, keyed objects): whatever adapter is
  configured serves the raw log, a test double included.

  Each object is registered in `raw_log_objects` *before* it is written, in its own tiny
  transaction, so `sweep/1` can delete objects older than the raw retention, orphans of a
  failed commit included, without listing the store.
  """

  import Ecto.Query
  alias Conveyor.Blobs.Adapter
  alias Conveyor.Repo

  @prefix "rawlog"

  @doc "Whether the writer puts raw bytes into objects (`RAW_LOG=blob`) or into rows."
  @spec blob_mode?() :: boolean()
  def blob_mode?, do: Application.get_env(:conveyor, __MODULE__, [])[:mode] == :blob

  @doc "The writer's hold in blob mode: one object per shard per interval."
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: Application.get_env(:conveyor, __MODULE__, [])[:flush_ms] || 1000

  @doc """
  In blob mode a writer shard flushes before its hold once this many bytes of batches
  (event and log bytes as received, before compression) wait, so flat-out load fills
  objects instead of waiting out the hold.
  """
  @spec flush_bytes() :: pos_integer()
  def flush_bytes,
    do: Application.get_env(:conveyor, __MODULE__, [])[:flush_bytes] || 4 * 1024 * 1024

  @object_fields [:object_key, :object_offset, :object_length]

  @doc "The columns a segment row carries in blob mode."
  def object_fields, do: @object_fields

  @doc """
  Moves the bytes of a group's segment rows (`{event row | nil, log row | nil}` per unit,
  in order) into one object body: every row gets the byte range it will occupy (events of
  all units first, then logs) and a nil payload. Returns the rows, the key and the body.
  """
  @spec objectify([{map() | nil, map() | nil}], term()) ::
          {[{map() | nil, map() | nil}], String.t(), iodata()}
  def objectify(pairs, shard) do
    key = new_key(shard)
    {events, acc} = Enum.map_reduce(pairs, {0, []}, &move(elem(&1, 0), :payload, key, &2))
    {logs, {_, parts}} = Enum.map_reduce(pairs, acc, &move(elem(&1, 1), :data, key, &2))
    {Enum.zip(events, logs), key, Enum.reverse(parts)}
  end

  defp move(nil, _col, _key, acc), do: {nil, acc}

  defp move(row, col, key, {offset, parts}) do
    bytes = Map.fetch!(row, col)

    row =
      row
      |> Map.put(col, nil)
      |> Map.merge(%{object_key: key, object_offset: offset, object_length: byte_size(bytes)})

    {row, {offset + byte_size(bytes), [bytes | parts]}}
  end

  # Rows of one build in one object are read with one range when the gap between two
  # consecutive ranges is at most this (another build's rows of the same group commit sit
  # between them), and a coalesced range never exceeds this many bytes.
  @coalesce_gap 256 * 1024
  @coalesce_max 8 * 1024 * 1024

  @doc """
  Fills `col` (`:payload` or `:data`) of segment rows, in order: rows that carry the bytes
  are left alone; rows that carry a byte range are fetched, and consecutive rows of the
  same object with contiguous or near-contiguous ranges are fetched with one `get_range/3`
  and split by each row's offset and length (PLAN §25 step 2 "Reads").
  """
  @spec fetch_rows!([map()], :payload | :data) :: [map()]
  def fetch_rows!(rows, col) do
    rows
    |> Enum.chunk_while([], &chunk_rows(&1, &2, col), fn
      [] -> {:cont, []}
      run -> {:cont, Enum.reverse(run), []}
    end)
    |> Enum.flat_map(&fetch_run!(&1, col))
  end

  # A run is a list (newest first) of rows that share an object and read as one range.
  defp chunk_rows(row, [], _col), do: {:cont, [row]}

  defp chunk_rows(row, [last | _] = run, col) do
    if coalesce?(last, row, run, col),
      do: {:cont, [row | run]},
      else: {:cont, Enum.reverse(run), [row]}
  end

  defp coalesce?(last, row, run, col) do
    is_nil(Map.get(row, col)) and is_nil(Map.get(last, col)) and
      row.object_key == last.object_key and
      row.object_offset >= last.object_offset + last.object_length and
      row.object_offset - (last.object_offset + last.object_length) <= @coalesce_gap and
      row.object_offset + row.object_length - List.last(run).object_offset <= @coalesce_max
  end

  defp fetch_run!([%{} = row] = run, col) do
    if is_binary(Map.get(row, col)), do: run, else: fetch_range!(run, col)
  end

  defp fetch_run!(run, col), do: fetch_range!(run, col)

  defp fetch_range!([first | _] = run, col) do
    last = List.last(run)
    offset = first.object_offset
    length = last.object_offset + last.object_length - offset

    case get_range(first.object_key, offset, length) do
      {:ok, bin} ->
        Enum.map(run, fn row ->
          Map.put(row, col, binary_part(bin, row.object_offset - offset, row.object_length))
        end)

      {:error, reason} ->
        raise "raw log #{first.object_key} range #{offset}+#{length}: #{inspect(reason)}"
    end
  end

  @doc "A fresh, time-ordered object key for a shard of this node."
  @spec new_key(term()) :: String.t()
  def new_key(shard) do
    ms = System.os_time(:millisecond)
    rand = :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
    node = node() |> Atom.to_string() |> String.replace(~r/[^a-z0-9]+/i, "-")

    "#{@prefix}/#{node}/#{shard}/#{ms |> Integer.to_string(32) |> String.downcase() |> String.pad_leading(10, "0")}#{rand}"
  end

  @doc """
  Registers and writes an object. The row goes first in its own transaction; the bytes
  are durable when this returns `:ok` (`c:Conveyor.Blobs.Adapter.put_object/3`; on disk
  see `fsync?/0`).
  """
  @spec put(String.t(), iodata()) :: :ok | {:error, term()}
  def put(key, iodata) do
    Repo.insert_all("raw_log_objects", [%{key: key}], on_conflict: :nothing)
    {adapter, opts} = Conveyor.Blobs.adapter()
    Adapter.counted(:put_object, adapter.put_object(key, iodata, [fsync: fsync?()] ++ opts))
  end

  @doc """
  Whether a disk put is synced before it returns (`RAW_LOG_FSYNC`, default true). Without
  it an acknowledged batch can lose its bytes when the machine (not just the node) dies
  before the page cache is written; only for stores where that is acceptable.
  """
  @spec fsync?() :: boolean()
  def fsync?, do: Keyword.get(Application.get_env(:conveyor, __MODULE__, []), :fsync, true)

  @doc "Reads `length` bytes at `offset` of an object."
  @spec get_range(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def get_range(key, offset, length) do
    :telemetry.execute([:conveyor, :raw_log, :get_range], %{count: 1, bytes: length}, %{key: key})
    {adapter, opts} = Conveyor.Blobs.adapter()
    Adapter.counted(:get_range, adapter.get_range(key, offset, length, opts))
  end

  @sweep_page 1000

  @doc """
  Deletes the objects registered before `cutoff`, then their rows, page by page until none
  is left or the deadline passes (`:deadline_ms`, default ten minutes; `:page`, default
  1,000 keys, the most one S3 DeleteObjects takes).

  A page's objects go first, in bulk; the rows go only for the keys the store reports
  deleted or absent (`docs/spec/RawLog.tla`: bytes, then row, so an object without a row
  never exists). A key the store refuses keeps its row, is counted
  (`[:conveyor, :raw_log, :sweep_failed]`) and is passed over for the rest of this run: the
  next run tries it again. `remaining?` is true when the deadline ended the run.
  """
  @spec sweep(DateTime.t(), keyword()) ::
          %{deleted: non_neg_integer(), failed: non_neg_integer(), remaining?: boolean()}
  def sweep(%DateTime{} = cutoff, opts \\ []) do
    page = Keyword.get(opts, :page, @sweep_page)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :deadline_ms, 600_000)
    sweep_pages(cutoff, nil, page, deadline, %{deleted: 0, failed: 0, remaining?: false})
  end

  defp sweep_pages(cutoff, cursor, page, deadline, acc) do
    case due_page(cutoff, cursor, page) do
      [] ->
        acc

      rows ->
        keys = Enum.map(rows, &elem(&1, 1))
        {deleted, failed} = delete_many(keys)
        Repo.delete_all(from(o in "raw_log_objects", where: o.key in ^deleted))

        Enum.each(failed, fn {key, reason} ->
          :telemetry.execute([:conveyor, :raw_log, :sweep_failed], %{count: 1}, %{
            key: key,
            reason: reason
          })
        end)

        acc = %{acc | deleted: acc.deleted + length(deleted), failed: acc.failed + length(failed)}

        cond do
          length(rows) < page -> acc
          System.monotonic_time(:millisecond) >= deadline -> %{acc | remaining?: true}
          true -> sweep_pages(cutoff, List.last(rows), page, deadline, acc)
        end
    end
  end

  # Oldest first, by the index on `inserted_at`; the cursor steps over keys whose delete
  # failed, so one refused object never stalls the run.
  defp due_page(cutoff, cursor, page) do
    from(o in "raw_log_objects",
      where: o.inserted_at < ^cutoff,
      order_by: [o.inserted_at, o.key],
      limit: ^page,
      select: {o.inserted_at, o.key}
    )
    |> after_cursor(cursor)
    |> Repo.all()
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, key}),
    do: where(query, [o], o.inserted_at > ^at or (o.inserted_at == ^at and o.key > ^key))

  @doc """
  What the sweep has not done yet: how many objects are registered before `cutoff`
  (counted up to `limit`) and how many seconds the oldest of them is past it.
  """
  @spec sweep_backlog(DateTime.t(), pos_integer()) ::
          %{objects: non_neg_integer(), overdue_seconds: non_neg_integer()}
  def sweep_backlog(%DateTime{} = cutoff, limit \\ 100_000) do
    due = from(o in "raw_log_objects", where: o.inserted_at < ^cutoff)

    case Repo.one(from(o in due, select: min(o.inserted_at))) do
      nil ->
        %{objects: 0, overdue_seconds: 0}

      oldest ->
        counted = from(o in due, select: o.key, limit: ^limit)

        %{
          objects: Repo.aggregate(subquery(counted), :count),
          overdue_seconds:
            max(DateTime.diff(cutoff, DateTime.from_naive!(oldest, "Etc/UTC"), :second), 0)
        }
    end
  end

  # Objects that are gone (deleted now or absent already) and the ones that are not.
  defp delete_many(keys) do
    {adapter, opts} = Conveyor.Blobs.adapter()
    {deleted, failed} = adapter.delete_objects(keys, opts)
    Enum.each(failed, fn {_key, reason} -> Adapter.counted(:delete_objects, {:error, reason}) end)
    {deleted, failed}
  end
end
