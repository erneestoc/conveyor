defmodule Conveyor.Bep.Fixture do
  @moduledoc """
  Reads Build Event Protocol files written by `bazel --build_event_binary_file=PATH`.

  The format is a sequence of `build_event_stream.BuildEvent` messages, each prefixed by
  its length as a protobuf varint (the same framing `--build_event_binary_file` and
  `--build_event_json_file`'s binary sibling use).
  """

  import Bitwise

  alias BuildEventStream.BuildEvent

  @doc "Reads and decodes every event in the file. Raises on malformed input."
  @spec read!(Path.t()) :: [BuildEvent.t()]
  def read!(path) do
    path |> File.read!() |> decode_all!()
  end

  @doc "Decodes a varint-delimited binary of `BuildEvent`s."
  @spec decode_all!(binary()) :: [BuildEvent.t()]
  def decode_all!(binary), do: binary |> frames() |> Enum.map(&BuildEvent.decode/1)

  @doc "Encodes events back into the varint-delimited format."
  @spec encode_all([BuildEvent.t()]) :: iodata()
  def encode_all(events) do
    Enum.map(events, fn event ->
      bytes = BuildEvent.encode(event)
      [encode_varint(byte_size(bytes)), bytes]
    end)
  end

  @doc "Splits a varint-delimited binary into raw message frames without decoding them."
  @spec frames(binary()) :: [binary()]
  def frames(binary), do: frames(binary, [])

  defp frames(<<>>, acc), do: Enum.reverse(acc)

  defp frames(binary, acc) do
    {len, rest} = decode_varint(binary)

    case rest do
      <<frame::binary-size(^len), rest::binary>> ->
        frames(rest, [frame | acc])

      _ ->
        raise ArgumentError, "truncated BEP frame: expected #{len} bytes, got #{byte_size(rest)}"
    end
  end

  @doc false
  def decode_varint(binary), do: decode_varint(binary, 0, 0)

  defp decode_varint(<<0::1, value::7, rest::binary>>, shift, acc),
    do: {acc ||| value <<< shift, rest}

  defp decode_varint(<<1::1, value::7, rest::binary>>, shift, acc) when shift < 63,
    do: decode_varint(rest, shift + 7, acc ||| value <<< shift)

  defp decode_varint(_, _, _), do: raise(ArgumentError, "invalid varint prefix in BEP file")

  @doc false
  def encode_varint(n) when n < 128, do: <<n>>
  def encode_varint(n), do: <<1::1, n &&& 0x7F::7, encode_varint(n >>> 7)::binary>>
end
