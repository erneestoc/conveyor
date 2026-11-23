defmodule Conveyor.Rbe.StreamActions do
  @moduledoc """
  The compact record of a successful `ActionExecuted` event of
  `--build_event_publish_all_actions`, and the chunk such records are stored in
  (PLAN §28.2). Pure: no database, no process, no protobuf struct; the ingest path hands
  in the fields of the event.

  ## The key (`key_source` 2, "stream")

  The first 8 bytes of SHA-256 over `"conveyor-stream-key-v1\\0"`, the label, the
  mnemonic, the primary output path and the SHA-256 of the command line (each argument
  length-prefixed), each part length-prefixed. The command line is hashed argument by
  argument and never kept. At one commit this identifies an action exactly; across
  commits it over-counts (a changed input the command line does not name), which is why
  the report states a same-commit floor and an any-commit ceiling.

  ## The record

  `{key, start µs | nil, duration µs, mnemonic, label, hit?}`. An event without usable
  times (Bazel 7: no times; 8.0 to 8.5: `end == start`) has start `nil` or duration 0 and
  is counted, not timed (`timed?/1`). A cache hit carries the times of the original
  execution, so it is the action that started before its build did.

  ## The chunk

  One binary per batch of records: a version byte, then zstd over a term-free columnar
  layout (keys, starts, durations, mnemonic indices, label indices, flags, then the two
  string tables), so equal bytes sit next to each other. `decode/1` returns the records
  in the order they were added.
  """

  @version 1
  @domain "conveyor-stream-key-v1\0"
  @key_source 2
  @no_start -0x8000000000000000

  @type action ::
          {key :: <<_::64>>, start_us :: integer() | nil, duration_us :: non_neg_integer(),
           mnemonic :: String.t(), label :: String.t(), hit? :: boolean()}

  @doc "The `key_source` of a stream key (beside 0, Bazel's digest, and 1, the fallback)."
  @spec key_source() :: 2
  def key_source, do: @key_source

  @doc "The 8-byte stream key of an action."
  @spec key(String.t(), String.t(), String.t(), [String.t()]) :: <<_::64>>
  def key(label, mnemonic, primary_output, command_line) do
    args =
      Enum.reduce(command_line, :crypto.hash_init(:sha256), fn arg, acc ->
        :crypto.hash_update(acc, prefixed(arg))
      end)

    <<key::binary-size(8), _::binary>> =
      :crypto.hash(:sha256, [
        @domain,
        prefixed(label),
        prefixed(mnemonic),
        prefixed(primary_output),
        prefixed(:crypto.hash_final(args))
      ])

    key
  end

  defp prefixed(bin), do: [<<byte_size(bin)::64>>, bin]

  @doc """
  The record of one successful action. `start_us`/`end_us` are the event's times in
  microseconds since the epoch or nil; `build_start_us` is `BuildStarted.start_time` or
  nil (then nothing is a hit and every action counts as executed).
  """
  @spec record(
          String.t(),
          String.t(),
          String.t(),
          [String.t()],
          integer() | nil,
          integer() | nil,
          integer() | nil
        ) :: action()
  def record(label, mnemonic, primary_output, command_line, start_us, end_us, build_start_us) do
    duration = if start_us && end_us && end_us > start_us, do: end_us - start_us, else: 0
    hit? = start_us != nil and build_start_us != nil and start_us < build_start_us

    {key(label, mnemonic, primary_output, command_line), start_us, duration, mnemonic, label,
     hit?}
  end

  @doc "True when the record has a start and a duration (Bazel 8.6 and later)."
  @spec timed?(action()) :: boolean()
  def timed?({_key, start, duration, _mnemonic, _label, _hit}),
    do: start != nil and duration > 0

  @doc "A chunk of the records, in order. `[]` encodes to a chunk that decodes to `[]`."
  @spec encode([action()]) :: binary()
  def encode(records) do
    {mnemonics, mnemonic_ids} = table(records, 3)
    {labels, label_ids} = table(records, 4)

    columns = [
      <<length(records)::32, length(mnemonics)::32, length(labels)::32>>,
      for({key, _, _, _, _, _} <- records, do: key),
      for({_, start, _, _, _, _} <- records, do: <<start || @no_start::signed-64>>),
      for({_, _, duration, _, _, _} <- records, do: <<duration::64>>),
      for({_, _, _, m, _, _} <- records, do: <<Map.fetch!(mnemonic_ids, m)::16>>),
      for({_, _, _, _, l, _} <- records, do: <<Map.fetch!(label_ids, l)::32>>),
      for({_, _, _, _, _, hit?} <- records, do: if(hit?, do: 1, else: 0)),
      Enum.map(mnemonics, &strz/1),
      Enum.map(labels, &strz/1)
    ]

    IO.iodata_to_binary([@version, :zstd.compress(columns)])
  end

  @doc "The records of a chunk made by `encode/1`."
  @spec decode(binary()) :: [action()]
  def decode(<<@version, compressed::binary>>) do
    <<n::32, nm::32, nl::32, rest::binary>> =
      compressed |> :zstd.decompress() |> IO.iodata_to_binary()

    <<keys::binary-size(^n * 8), starts::binary-size(^n * 8), durations::binary-size(^n * 8),
      mnemonic_ids::binary-size(^n * 2), label_ids::binary-size(^n * 4), flags::binary-size(^n),
      strings::binary>> = rest

    {mnemonics, strings} = strings(strings, nm)
    {labels, ""} = strings(strings, nl)

    [
      for(<<k::binary-size(8) <- keys>>, do: k),
      for(<<s::signed-64 <- starts>>, do: if(s == @no_start, do: nil, else: s)),
      for(<<d::64 <- durations>>, do: d),
      for(<<m::16 <- mnemonic_ids>>, do: elem(mnemonics, m)),
      for(<<l::32 <- label_ids>>, do: elem(labels, l)),
      for(<<f <- flags>>, do: f == 1)
    ]
    |> Enum.zip()
  end

  # The distinct strings at tuple position `at`, in order of first use, and their indices.
  defp table(records, at) do
    {list, ids} =
      Enum.reduce(records, {[], %{}}, fn record, {list, ids} = acc ->
        s = elem(record, at)
        if Map.has_key?(ids, s), do: acc, else: {[s | list], Map.put(ids, s, map_size(ids))}
      end)

    {Enum.reverse(list), ids}
  end

  defp strz(s), do: [<<byte_size(s)::32>>, s]

  defp strings(bin, n) do
    {list, rest} =
      Enum.reduce(List.duplicate(nil, n), {[], bin}, fn _,
                                                        {acc,
                                                         <<len::32, s::binary-size(len),
                                                           rest::binary>>} ->
        {[s | acc], rest}
      end)

    {list |> Enum.reverse() |> List.to_tuple(), rest}
  end
end
