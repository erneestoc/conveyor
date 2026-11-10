defmodule Conveyor.RawStore.Codec do
  @moduledoc """
  How raw bytes are encoded at rest, in every form the store keeps them in: zstd frames
  (events with the BEP dictionary, log text without), and events inside a frame as a
  `--build_event_binary_file` (each protobuf message behind its varint length).

  Raw BEP frames repeat the same field names and labels in every event; a dictionary
  trained on them (priv/zstd/bep-<id>.dict, bench/train_dict.sh) roughly doubles the
  ratio of a segment-sized frame (PLAN §24 item 3). A compressed frame carries the
  dictionary id, so `decompress/1` picks the right one and frames written without any
  still decode.
  """
  import Bitwise

  @bep_dict_id 1

  @doc "Compresses log text (no dictionary)."
  @spec compress(iodata()) :: binary()
  def compress(iodata), do: iodata |> :zstd.compress() |> IO.iodata_to_binary()

  @doc "Compresses BEP frames with the BEP dictionary."
  @spec compress_bep(iodata()) :: binary()
  def compress_bep(iodata) do
    iodata
    |> :zstd.compress(%{dictionary: dict(:compress, @bep_dict_id)})
    |> IO.iodata_to_binary()
  end

  @doc """
  `compress_bep/1` and `compress/1` over two zstd contexts made here and reused by every
  call: for a process that compresses many small frames (a writer shard), where creating a
  context per call costs about a third of the compression. Same frames, same readers. The
  contexts belong to the calling process and live as long as the functions do.
  """
  @spec compressors() :: %{bep: (iodata() -> binary()), text: (iodata() -> binary())}
  def compressors do
    {:ok, bep} = :zstd.context(:compress, %{dictionary: dict(:compress, @bep_dict_id)})
    {:ok, text} = :zstd.context(:compress, %{})

    %{
      bep: fn iodata -> iodata |> :zstd.compress(bep) |> IO.iodata_to_binary() end,
      text: fn iodata -> iodata |> :zstd.compress(text) |> IO.iodata_to_binary() end
    }
  end

  @doc "Decompresses one frame, with the dictionary its header names."
  @spec decompress(binary()) :: binary()
  def decompress(binary) do
    case :zstd.get_frame_header(binary) do
      {:ok, %{dictID: 0}} -> :zstd.decompress(binary)
      {:ok, %{dictID: id}} -> :zstd.decompress(binary, %{dictionary: dict(:decompress, id)})
    end
    |> IO.iodata_to_binary()
  end

  @doc """
  Compresses or decompresses a stream of chunks through one zstd context, so a build of
  any size is never held in memory whole. Compression with `dictionary: true` uses the BEP
  dictionary and records its id in the frame; decompression reads the id from the frame
  header and loads the matching dictionary.
  """
  @spec stream(Enumerable.t(), :compress | :decompress, keyword()) :: Enumerable.t()
  def stream(chunks, mode, opts \\ []) do
    Stream.transform(
      chunks,
      fn -> {:zstd, nil, ""} end,
      fn chunk, {:zstd, ctx, pending} -> feed(ctx, pending <> chunk, mode, opts) end,
      fn
        {:zstd, nil, ""} = acc ->
          {[], acc}

        {:zstd, ctx, pending} ->
          ctx = ctx || context(mode, pending, opts)
          {:done, out} = :zstd.finish(ctx, pending)
          {[IO.iodata_to_binary(out)], {:zstd, ctx, ""}}
      end,
      fn
        {:zstd, nil, _} -> :ok
        {:zstd, ctx, _} -> :zstd.close(ctx)
      end
    )
    |> Stream.reject(&(&1 == ""))
  end

  # Decompression needs the frame header (up to 18 bytes) to pick the dictionary.
  defp feed(nil, data, :decompress, _opts) when byte_size(data) < 18,
    do: {[], {:zstd, nil, data}}

  defp feed(nil, data, mode, opts), do: feed(context(mode, data, opts), data, mode, opts)

  defp feed(ctx, data, _mode, _opts) do
    {:continue, out} = :zstd.stream(ctx, data)
    {[IO.iodata_to_binary(out)], {:zstd, ctx, ""}}
  end

  defp context(:compress, _data, opts) do
    params =
      if Keyword.get(opts, :dictionary, false),
        do: %{dictionary: dict(:compress, @bep_dict_id)},
        else: %{}

    {:ok, ctx} = :zstd.context(:compress, params)
    ctx
  end

  defp context(:decompress, data, _opts) do
    params =
      case :zstd.get_frame_header(data) do
        {:ok, %{dictID: id}} when id != 0 -> %{dictionary: dict(:decompress, id)}
        _ -> %{}
      end

    {:ok, ctx} = :zstd.context(:decompress, params)
    ctx
  end

  # Dictionaries are loaded once per node.
  defp dict(mode, id) do
    key = {__MODULE__, :zstd_dict, mode, id}

    case :persistent_term.get(key, nil) do
      nil ->
        bytes = File.read!(Path.join([:code.priv_dir(:conveyor), "zstd", "bep-#{id}.dict"]))
        {:ok, dict} = :zstd.dict(mode, bytes)
        :persistent_term.put(key, dict)
        dict

      dict ->
        dict
    end
  end

  # --- BEP framing ------------------------------------------------------------------------

  @doc "One event as it sits in a `--build_event_binary_file`: varint length, then the message."
  @spec frame(binary()) :: iodata()
  def frame(message), do: [varint(byte_size(message)), message]

  defp varint(n) when n < 128, do: <<n>>
  defp varint(n), do: <<1::1, n &&& 0x7F::7, varint(n >>> 7)::binary>>

  @doc "The messages of a whole `--build_event_binary_file` binary, in order."
  @spec frames(binary()) :: [binary()]
  def frames(binary) do
    case take_frames(binary, []) do
      {frames, ""} -> frames
      {_frames, rest} -> raise ArgumentError, "truncated BEP frame: #{byte_size(rest)} bytes left"
    end
  end

  @doc """
  The messages of a `--build_event_binary_file` that arrives in chunks, as a lazy stream:
  a consumer that stops early stops the source too, and no more than a chunk and a
  message is held at once.
  """
  @spec frame_stream(Enumerable.t()) :: Enumerable.t()
  def frame_stream(chunks) do
    Stream.transform(
      chunks,
      fn -> "" end,
      fn chunk, pending -> take_frames(pending <> chunk, []) end,
      fn
        "" -> {[], ""}
        rest -> raise ArgumentError, "truncated BEP frame: #{byte_size(rest)} bytes left"
      end,
      fn _ -> :ok end
    )
  end

  defp take_frames(binary, acc) do
    case read_varint(binary, 0, 0) do
      {length, rest} when byte_size(rest) >= length ->
        <<frame::binary-size(^length), rest::binary>> = rest
        take_frames(rest, [frame | acc])

      _incomplete ->
        {Enum.reverse(acc), binary}
    end
  end

  defp read_varint(<<0::1, value::7, rest::binary>>, shift, acc),
    do: {acc ||| value <<< shift, rest}

  defp read_varint(<<1::1, value::7, rest::binary>>, shift, acc) when shift < 63,
    do: read_varint(rest, shift + 7, acc ||| value <<< shift)

  defp read_varint(<<>>, _shift, _acc), do: :incomplete
  defp read_varint(_, _, _), do: raise(ArgumentError, "invalid varint prefix in BEP stream")
end
