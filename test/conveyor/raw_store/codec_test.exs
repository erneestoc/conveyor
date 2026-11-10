defmodule Conveyor.RawStore.CodecTest do
  use ExUnit.Case, async: true

  alias Conveyor.RawStore.Codec

  defp fixture(name),
    do: File.read!(Path.join([File.cwd!(), "test/fixtures/bep", name <> ".bep"]))

  test "events use the BEP dictionary, log text none, and both decode by their frame header" do
    with_dict = Codec.compress_bep(["abc", "defg"])
    plain = Codec.compress(["abc", "defg"])
    assert {:ok, %{dictID: 1}} = :zstd.get_frame_header(with_dict)
    assert {:ok, %{dictID: 0}} = :zstd.get_frame_header(plain)
    assert Codec.decompress(with_dict) == "abcdefg"
    assert Codec.decompress(plain) == "abcdefg"

    # A real event stream: the dictionary earns its keep.
    raw = fixture("clean_build_and_test")
    assert byte_size(Codec.compress_bep(raw)) < byte_size(Codec.compress(raw)) * 0.8
    assert Codec.decompress(Codec.compress_bep(raw)) == raw

    # A process's reusable compressors write the same frames.
    %{bep: bep, text: text} = Codec.compressors()
    assert Codec.decompress(bep.(raw)) == raw
    assert {:ok, %{dictID: 1}} = :zstd.get_frame_header(bep.("x"))
    assert Codec.decompress(text.(["log ", "text"])) == "log text"
  end

  test "a stream is compressed and decompressed chunk by chunk, with or without the dictionary" do
    raw = fixture("build_only_verbose")
    chunks = for <<chunk::binary-size(1000) <- raw>>, do: chunk
    whole = IO.iodata_to_binary(chunks)

    for opts <- [[dictionary: true], []] do
      compressed =
        chunks |> Codec.stream(:compress, opts) |> Enum.to_list() |> IO.iodata_to_binary()

      id = if opts == [], do: 0, else: 1
      assert {:ok, %{dictID: ^id}} = :zstd.get_frame_header(compressed)
      assert Codec.decompress(compressed) == whole

      # Fed back a few bytes at a time: the header is waited for, nothing is lost.
      pieces = for <<piece::binary-size(7) <- compressed>>, do: piece
      rest = binary_part(compressed, length(pieces) * 7, rem(byte_size(compressed), 7))

      assert (pieces ++ [rest])
             |> Codec.stream(:decompress)
             |> Enum.to_list()
             |> IO.iodata_to_binary() == whole
    end

    assert [] |> Codec.stream(:compress) |> Enum.to_list() == []
    assert [] |> Codec.stream(:decompress) |> Enum.to_list() == []
  end

  test "a chunk larger than zstd's own buffer goes through whole, in both directions" do
    # One call of the streaming API handles about 128 KB of output and hands back the
    # input it did not get to: a large incompressible chunk on the way in, a small chunk
    # that expands a lot on the way out. Both read back as fewer bytes or crashed.
    random = :crypto.strong_rand_bytes(1_500_000)
    text = String.duplicate("the same line again\n", 100_000)

    for {chunks, opts} <- [
          {[random], []},
          {[text], []},
          {["head", random, text, "tail"], [dictionary: true]}
        ] do
      whole = IO.iodata_to_binary(chunks)

      compressed =
        chunks |> Codec.stream(:compress, opts) |> Enum.to_list() |> IO.iodata_to_binary()

      assert Codec.decompress(compressed) == whole

      # The compressed text is a few hundred bytes that expand to two megabytes.
      assert [compressed] |> Codec.stream(:decompress) |> Enum.to_list() |> IO.iodata_to_binary() ==
               whole

      halves = [
        binary_part(compressed, 0, 20),
        binary_part(compressed, 20, byte_size(compressed) - 20)
      ]

      assert halves |> Codec.stream(:decompress) |> Enum.to_list() |> IO.iodata_to_binary() ==
               whole
    end
  end

  test "frames: a message behind its varint length, split whole or as the bytes arrive" do
    messages = [
      "",
      "a",
      String.duplicate("b", 127),
      String.duplicate("c", 128),
      :crypto.strong_rand_bytes(70_000)
    ]

    file = messages |> Enum.map(&Codec.frame/1) |> IO.iodata_to_binary()
    assert Codec.frames(file) == messages
    assert Codec.frames("") == []

    assert Codec.frames(fixture("clean_build_and_test")) ==
             Conveyor.Bep.Fixture.frames(fixture("clean_build_and_test"))

    # Chunk boundaries anywhere: inside a varint, inside a message.
    for size <- [1, 2, 3, 100, 65_536] do
      chunks = for <<chunk::binary-size(^size) <- file>>, do: chunk
      rest = binary_part(file, length(chunks) * size, rem(byte_size(file), size))
      assert (chunks ++ [rest]) |> Codec.frame_stream() |> Enum.to_list() == messages
    end

    # Lazy: taking the first messages does not read the rest.
    endless = Stream.cycle([IO.iodata_to_binary(Codec.frame("again"))])
    assert endless |> Codec.frame_stream() |> Enum.take(3) == ["again", "again", "again"]
  end

  test "a truncated or malformed file is an error, never fewer events" do
    file = IO.iodata_to_binary([Codec.frame("whole"), Codec.frame("cut short")])
    cut = binary_part(file, 0, byte_size(file) - 3)
    assert_raise ArgumentError, ~r/truncated/, fn -> Codec.frames(cut) end

    assert_raise ArgumentError, ~r/truncated/, fn ->
      [cut] |> Codec.frame_stream() |> Enum.to_list()
    end

    endless_varint = String.duplicate(<<0xFF>>, 11)
    assert_raise ArgumentError, ~r/varint/, fn -> Codec.frames(endless_varint) end
  end
end
