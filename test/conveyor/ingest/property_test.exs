defmodule Conveyor.Ingest.PropertyTest do
  @moduledoc """
  Properties of the pure parts of the pipeline (M9 D3): the normalizer's log accounting
  for arbitrary progress sequences, and the writer's cross-batch merge of keyed rows.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BuildEventStream, as: BES
  alias Conveyor.Ingest.{Batch, Normalizer, Writer}
  alias Conveyor.Invocations.Invocation

  @id "22222222-2222-4222-8222-222222222222"
  @day ~D[2026-09-18]

  defp progress(n, text) do
    %BES.BuildEvent{
      id: %BES.BuildEventId{id: {:progress, %BES.BuildEventId.ProgressId{opaque_count: n}}},
      payload: {:progress, %BES.Progress{stderr: text}}
    }
  end

  defp chunk do
    map({string(:utf8, max_length: 20), integer(0..3)}, fn {s, n} ->
      s <> String.duplicate("\n", n)
    end)
  end

  defp run(chunks, opts) do
    inv = %Invocation{id: @id, project_id: 1, started_at: ~U[2026-09-18 00:00:00Z]}

    chunks
    |> Enum.with_index(1)
    |> Enum.reduce({Normalizer.new(inv, opts), Batch.new(@id, 1, @day, 1, 0, 0)}, fn {text, seq},
                                                                                     {state,
                                                                                      batch} ->
      Normalizer.apply(state, progress(seq, text), seq, batch)
    end)
  end

  property "log bytes, lines and the stored text follow any sequence of progress events" do
    check all(chunks <- list_of(chunk(), max_length: 30)) do
      {state, batch} = run(chunks, [])
      text = Enum.join(chunks)
      bytes = byte_size(text)
      lines = text |> :binary.matches("\n") |> length()

      assert state.inv.log_bytes == bytes and state.inv.log_lines == lines
      assert batch.log_bytes == bytes and batch.log_lines == lines
      assert state.inv.event_count == length(chunks)
      # Sequence numbers are the worker's business (Batch.add_event); the normalizer only
      # accounts for the text.
      assert batch.log |> Enum.reverse() |> Enum.map_join(&elem(&1, 1)) == text
      # Empty progress events are acknowledged but store no log row.
      assert length(batch.log) == Enum.count(chunks, &(&1 != ""))
    end
  end

  property "a log cap keeps the stored bytes at or under the cap and never splits a line count" do
    check all(
            chunks <- list_of(chunk(), min_length: 1, max_length: 30),
            cap <- integer(0..64)
          ) do
      {state, batch} = run(chunks, max_log_bytes: cap)
      stored = batch.log |> Enum.reverse() |> Enum.map_join(&elem(&1, 1))
      marker = "\n[conveyor: build log truncated at #{cap} bytes; the remainder was not stored]\n"
      text = Enum.join(chunks)

      # Either everything fitted, or exactly `cap` bytes were kept plus the marker.
      assert state.inv.log_bytes == byte_size(stored)
      assert state.inv.log_lines == stored |> :binary.matches("\n") |> length()

      if byte_size(text) <= cap do
        assert stored == text
      else
        assert byte_size(stored) == cap + byte_size(marker)
        assert binary_part(stored, 0, cap) == binary_part(text, 0, cap)
        assert String.ends_with?(stored, marker)
      end
    end
  end

  defp target_batch do
    keys = member_of([{"//a:a", ""}, {"//a:b", ""}, {"//a:b", "asp"}, {"//c:d", ""}])
    # Any subset of three attributes with small values, so that batches overlap heavily.
    attrs =
      map({integer(0..9), integer(0..9), integer(0..9), integer(0..7)}, fn {s, k, d, mask} ->
        [status: s, kind: k, duration_ms: d]
        |> Enum.with_index()
        |> Enum.filter(fn {_, i} -> Bitwise.band(mask, Bitwise.bsl(1, i)) != 0 end)
        |> Map.new(fn {{f, v}, _} -> {f, v} end)
      end)

    map(
      {member_of([@id, "33333333-3333-4333-8333-333333333333"]),
       list_of({keys, attrs}, max_length: 6)},
      fn {inv, upserts} ->
        Enum.reduce(upserts, Batch.new(inv, 1, @day, 1, 0, 0), fn {{label, aspect}, a}, b ->
          Batch.upsert_target(b, {label, aspect}, Map.merge(a, %{label: label, aspect: aspect}))
        end)
      end
    )
  end

  property "the writer's merged target rows equal applying every upsert in order, one row per key" do
    check all(batches <- list_of(target_batch(), min_length: 1, max_length: 5)) do
      rows = Writer.plan(batches).targets

      expected =
        batches
        |> Enum.flat_map(fn b ->
          Enum.map(b.targets, fn {key, attrs} -> {b.invocation_id, key, attrs} end)
        end)
        |> Enum.reduce(%{}, fn {inv, key, attrs}, acc ->
          Map.update(acc, {inv, key}, Map.put(attrs, :invocation_id, inv), &Map.merge(&1, attrs))
        end)
        |> Map.values()

      sort = &Enum.sort_by(&1, fn r -> {r.invocation_id, r.label, r.aspect} end)
      assert sort.(rows) == sort.(expected)

      assert rows |> Enum.map(&{&1.invocation_id, &1.label, &1.aspect}) |> Enum.uniq() |> length() ==
               length(rows)
    end
  end
end
