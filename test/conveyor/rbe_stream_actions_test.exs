defmodule Conveyor.Rbe.StreamActionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Conveyor.Rbe.StreamActions

  @t0 1_795_000_000_000_000

  test "the key is 8 bytes and depends on every part and on argument boundaries" do
    key = StreamActions.key("//a:b", "GoCompile", "bazel-out/a/b.a", ["go", "build", "-o"])

    assert byte_size(key) == 8

    assert key ==
             StreamActions.key("//a:b", "GoCompile", "bazel-out/a/b.a", ["go", "build", "-o"])

    assert StreamActions.key_source() == 2

    others = [
      StreamActions.key("//a:c", "GoCompile", "bazel-out/a/b.a", ["go", "build", "-o"]),
      StreamActions.key("//a:b", "GoLink", "bazel-out/a/b.a", ["go", "build", "-o"]),
      StreamActions.key("//a:b", "GoCompile", "bazel-out/a/c.a", ["go", "build", "-o"]),
      StreamActions.key("//a:b", "GoCompile", "bazel-out/a/b.a", ["go", "build-o"]),
      StreamActions.key("//a:b", "GoCompile", "bazel-out/a/b.a", ["go", "buil", "d-o"]),
      StreamActions.key("//a:bGoCompile", "", "bazel-out/a/b.a", ["go", "build", "-o"])
    ]

    assert length(Enum.uniq([key | others])) == 7
  end

  test "a record is a hit when it started before its build, and timed when end is after start" do
    args = ["cc", "-c"]
    record = &StreamActions.record("//x:y", "CppCompile", "x/y.o", args, &1, &2, &3, 7)

    assert {key, @t0, 1_500, "CppCompile", "//x:y", false, 7} = r = record.(@t0, @t0 + 1_500, @t0)
    assert StreamActions.timed?(r)
    assert StreamActions.execution?(r)
    assert key == StreamActions.key("//x:y", "CppCompile", "x/y.o", args)

    # A cache hit carries the original execution's times.
    # A cache hit carries the original execution's times, and keeps them with its key.
    origin = @t0 - 9_000
    assert {^key, ^origin, 2_000, _, _, true, _} = hit = record.(origin, @t0 - 7_000, @t0)
    assert StreamActions.timed?(hit)
    refute StreamActions.execution?(hit)
    assert StreamActions.linked_hit?(hit)

    # Without BuildStarted's time nothing is a hit.
    assert {_, _, 2_000, _, _, false, _} = record.(@t0 - 9_000, @t0 - 7_000, nil)

    # Bazel 8.0 to 8.5: end == start. Bazel 7: no times.
    assert {<<0::64>>, nil, 0, _, _, false, _} = flat = record.(@t0, @t0, @t0)
    refute StreamActions.timed?(flat)
    assert {_, nil, 0, _, _, false, _} = none = record.(nil, nil, @t0)
    refute StreamActions.timed?(none)
    assert {_, nil, 0, _, _, false, _} = record.(@t0, nil, @t0)
  end

  test "an empty chunk" do
    assert StreamActions.decode(StreamActions.encode([])) == []
  end

  property "a chunk decodes to its records, in order" do
    record =
      gen all(
            label <- member_of(["//a:b", "//a:c", "@x//y:z", ""]),
            mnemonic <- member_of(["GoCompile", "CppCompile", "Genrule"]),
            out <- string(:alphanumeric, max_length: 12),
            args <- list_of(string(:printable, max_length: 8), max_length: 4),
            start <- one_of([constant(nil), integer((@t0 - 1_000_000)..(@t0 + 1_000_000))]),
            length <- integer(0..5_000_000),
            seq <- integer(1..100_000)
          ) do
        StreamActions.record(label, mnemonic, out, args, start, start && start + length, @t0, seq)
      end

    check all(records <- list_of(record, max_length: 40)) do
      assert StreamActions.decode(StreamActions.encode(records)) == records
    end
  end

  test "size of a chunk of 1,000 actions of 50 targets" do
    records =
      for i <- 1..1_000 do
        StreamActions.record(
          "//pkg/sub#{rem(i, 50)}:lib",
          Enum.at(["GoCompilePkg", "CppCompile", "GoLink"], rem(i, 3)),
          "bazel-out/k8-fastbuild/bin/pkg/sub#{rem(i, 50)}/#{i}.o",
          ["tool", "-o", "#{i}"],
          @t0 + i * 37_123,
          @t0 + i * 37_123 + 250_000 + rem(i * 7919, 900_000),
          @t0,
          2 * i
        )
      end

    bytes = byte_size(StreamActions.encode(records))

    IO.puts(
      "stream chunk: #{Float.round(bytes / 1_000, 1)} B per action (synthetic, 1,000 actions)"
    )

    assert bytes < 20_000
  end
end
