defmodule Conveyor.Ingest.PropertyTest do
  @moduledoc """
  Properties of the pure parts of the pipeline (M9 D3): the normalizer's log accounting
  for arbitrary progress sequences, and the writer's cross-batch merge of keyed rows.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BuildEventStream, as: BES
  alias Conveyor.Bep.Fixture
  alias Conveyor.Ingest.{Batch, Normalizer, Writer}
  alias Conveyor.Invocations
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

  # Contiguous batches of a few invocations, interleaved at random.
  defp interleaved_batches do
    gen all(
          per_invocation <-
            list_of(
              list_of(
                {integer(1..3), member_of(["a", "b"]), string(:alphanumeric, max_length: 4),
                 map_of(member_of(["//x", "//y"]), member_of(["configured", "success"]),
                   max_length: 2
                 )},
                min_length: 1,
                max_length: 4
              ),
              min_length: 1,
              max_length: 3
            ),
          seed <- integer()
        ) do
      per_invocation
      |> Enum.with_index()
      |> Enum.flat_map(fn {specs, i} ->
        id = "0000000#{i}-0000-4000-8000-000000000000"

        specs
        |> Enum.reduce({[], 1, 0, 0}, fn {n, kind, log, targets}, {acc, seq, bytes, lines} ->
          batch = Batch.new(id, 1, ~D[2026-09-18], seq, bytes, lines)

          batch =
            Enum.reduce(seq..(seq + n - 1), batch, fn s, b ->
              Batch.add_event(b, s, kind, "e#{s}")
            end)

          batch = Batch.add_log(batch, seq, log)

          batch =
            Enum.reduce(targets, batch, fn {label, status}, b ->
              Batch.upsert_target(b, {label, ""}, %{label: label, aspect: "", status: status})
            end)

          {[batch | acc], seq + n, bytes + batch.log_bytes, lines + batch.log_lines}
        end)
        |> elem(0)
        |> Enum.reverse()
      end)
      |> shuffle_stable(seed)
    end
  end

  # Random interleaving that keeps each invocation's own order.
  defp shuffle_stable(batches, seed) do
    batches
    |> Enum.with_index()
    |> Enum.sort_by(fn {b, i} -> {:erlang.phash2({seed, b.invocation_id, div(i, 2)}), i} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.group_by(& &1.invocation_id)
    |> Map.values()
    |> Enum.sort_by(&:erlang.phash2({seed, hd(&1).invocation_id}))
    |> Enum.reduce([], fn group, acc -> acc ++ group end)
  end

  property "coalescing batches changes the rows written, never the content" do
    check all(batches <- interleaved_batches()) do
      units = Batch.coalesce(batches)
      plain = Writer.plan(batches)
      merged = Writer.plan(units)

      # Every event once, contiguous per invocation, in the same order.
      frames = fn rows ->
        rows
        |> Enum.group_by(& &1.invocation_id)
        |> Map.new(fn {id, rs} ->
          {id,
           rs
           |> Enum.sort_by(& &1.first_seq)
           |> Enum.flat_map(&(&1.payload |> Invocations.decompress() |> Fixture.frames()))}
        end)
      end

      assert frames.(merged.event_rows) == frames.(plain.event_rows)

      assert Enum.sum(Enum.map(merged.event_rows, & &1.count)) ==
               Enum.sum(Enum.map(plain.event_rows, & &1.count))

      # The log text and its offsets chain identically.
      logs = fn rows ->
        rows
        |> Enum.group_by(& &1.invocation_id)
        |> Map.new(fn {id, rs} ->
          rs = Enum.sort_by(rs, & &1.byte_offset)

          {id,
           {hd(rs).byte_offset, Enum.map_join(rs, &Invocations.decompress(&1.data)),
            Enum.sum(Enum.map(rs, & &1.line_count))}}
        end)
      end

      assert logs.(merged.log_rows) == logs.(plain.log_rows)

      sort = &Enum.sort_by(&1, fn r -> {r.invocation_id, r.label} end)
      assert sort.(merged.targets) == sort.(plain.targets)
      assert length(units) <= length(batches)

      assert Enum.map(units, & &1.invocation_id) |> Enum.uniq() |> length() ==
               Enum.map(batches, & &1.invocation_id) |> Enum.uniq() |> length()
    end
  end
end
