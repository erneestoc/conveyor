defmodule Conveyor.RawStoreSeamTest do
  @moduledoc """
  Where a build's raw bytes live is `Conveyor.RawStore`'s knowledge. This test reads the
  sources and fails when another module starts to share it: selects the object columns of
  a segment row, tests `raw_status`, or calls the store's internals. A new entry in the
  lists below is a decision, not a fix: say in the commit why that module must know.
  """
  use ExUnit.Case, async: true

  # The store itself.
  @store ~w(
    lib/conveyor/raw_store.ex lib/conveyor/raw_store/codec.ex lib/conveyor/raw_store/segments.ex
    lib/conveyor/raw_store/expiry.ex lib/conveyor/raw_log.ex lib/conveyor/raw_archive.ex
  )

  # Schemas declare the columns; nothing more.
  @schemas ~w(lib/conveyor/invocations/segments.ex lib/conveyor/invocations/invocation.ex)

  @rules [
    # The forms: byte ranges, the archived blobs' status.
    {~r/object_key|object_offset|object_length|raw_status|raw_archived_at/, []},
    # The blobs a build references: the blob store's reference checks and the project move
    # treat them like the profile blob, as digests to keep or carry.
    {~r/\braw_blob\b|\blog_blob\b/, ~w(lib/conveyor/blobs.ex lib/conveyor/projects/move.ex)},
    # Segment rows: the commit transaction inserts the rows the store hands it.
    {~r/\bEventSegment\b|\bLogSegment\b/, ~w(lib/conveyor/ingest/writer/transaction.ex)},
    # The store's internals.
    {~r/(RawLog|RawArchive|RawStore\.(Codec|Segments|Expiry))\.[a-z_]+[(\/]/, []}
  ]

  test "no module outside the store knows the forms of a build's raw bytes" do
    sources = Path.wildcard("lib/**/*.{ex,heex}") -- (@store ++ @schemas)

    offences =
      for file <- sources,
          {pattern, allowed} <- @rules,
          file not in allowed,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          # Prose may name what it does not use.
          not String.match?(line, ~r/^\s*(#|\*)/),
          Regex.match?(pattern, line),
          do: "#{file}:#{number}: #{String.trim(line)}"

    assert offences == []
  end
end
