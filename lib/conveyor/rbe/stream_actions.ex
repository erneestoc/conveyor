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

  `{key, start µs | nil, duration µs, mnemonic, label, hit?, seq}`. `seq` is the sequence
  number of the event in its stream: the record's ordinal in the build. A timed action
  carries its key and its start; an untimed one is counted, never matched: its key is
  eight zero bytes and its start nil. A hit's start and duration are those of the
  execution it was served from: the duration is the time the cache saved, the start
  names that execution. An event without usable
  times (Bazel 7: no times; 8.0 to 8.5: `end == start`) has start `nil` or duration 0 and
  is counted, not timed (`timed?/1`). A cache hit carries the times of the original
  execution, so it is the action that started before its build did.

  ## The chunk

  One binary per batch of records: a version byte, then zstd over columns (the keys of
  the executions, finish times as distances, durations, mnemonic and label indices,
  flags, sequence numbers as distances, then the two string tables), so equal bytes sit
  next to each other. `decode/1` returns the records
  in the order they were added.
  """

  @version 1
  @domain "conveyor-stream-key-v1\0"
  @key_source 2
  @no_key <<0::64>>

  @type action ::
          {key :: <<_::64>>, start_us :: integer() | nil, duration_us :: non_neg_integer(),
           mnemonic :: String.t(), label :: String.t(), hit? :: boolean(),
           seq :: non_neg_integer()}

  @doc "The `key_source` of a stream key (beside 0, Bazel's digest, and 1, the fallback)."
  @spec key_source() :: 2
  def key_source, do: @key_source

  @doc "The 8-byte stream key of an action."
  @spec key(String.t(), String.t(), String.t(), [String.t()]) :: <<_::64>>
  def key(label, mnemonic, primary_output, command_line) do
    # One call over the arguments as iodata: the same bytes as an update per argument,
    # at a third of the time (30 to 36 arguments per action in the recorded builds).
    args = :crypto.hash(:sha256, for(arg <- command_line, do: [<<byte_size(arg)::64>> | arg]))

    <<key::binary-size(8), _::binary>> =
      :crypto.hash(:sha256, [
        @domain,
        prefixed(label),
        prefixed(mnemonic),
        prefixed(primary_output),
        prefixed(args)
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
          integer() | nil,
          non_neg_integer()
        ) :: action()
  def record(label, mnemonic, primary_output, command_line, start_us, end_us, build_start, seq) do
    duration = if start_us && end_us && end_us > start_us, do: end_us - start_us, else: 0
    hit? = start_us != nil and build_start != nil and start_us < build_start

    # A timed action keeps its key and its start. A hit's times are those of the
    # execution that filled the cache: its duration is the time the hit saved, and its
    # start names that execution (the evidence the estimate works from, PLAN §28.4).
    if duration > 0,
      do:
        {key(label, mnemonic, primary_output, command_line), start_us, duration, mnemonic, label,
         hit?, seq},
      else: {@no_key, nil, duration, mnemonic, label, hit?, seq}
  end

  @doc "True when the event had usable times (Bazel 8.6 and later; a hit has them too)."
  @spec timed?(action()) :: boolean()
  def timed?({_key, _start, duration, _mnemonic, _label, _hit, _seq}), do: duration > 0

  @doc "True when the record is an execution: timed and not served from a cache."
  @spec execution?(action()) :: boolean()
  def execution?({_key, start, _duration, _mnemonic, _label, hit?, _seq}),
    do: start != nil and not hit?

  @doc """
  True when the record is a cache hit that names the execution it was served from (its
  key and that execution's start). Chunks written before 2026-11-24 hold hits without.
  """
  @spec linked_hit?(action()) :: boolean()
  def linked_hit?({_key, start, _duration, _mnemonic, _label, hit?, _seq}),
    do: start != nil and hit?

  @doc "A chunk of the records, in order. `[]` encodes to a chunk that decodes to `[]`."
  @spec encode([action()]) :: binary()
  def encode(records) do
    {mnemonics, mnemonic_ids} = table(records, 3)
    {labels, label_ids} = table(records, 4)

    # Sequence numbers as the distance to the record before: small and mostly equal.
    {seqs, _} =
      Enum.map_reduce(records, 0, fn record, last ->
        seq = elem(record, 6)
        {<<seq - last::signed-64>>, seq}
      end)

    # Finish times as the distance to the execution before: events arrive in the order
    # actions finish, so the distances are small. Hits have their own chain: their times are those of
    # earlier builds.
    {ends, _} =
      Enum.map_reduce(records, {0, 0}, fn
        {_, nil, _, _, _, _, _}, last ->
          {<<0::64>>, last}

        {_, start, duration, _, _, true, _}, {last, last_hit} ->
          {<<start + duration - last_hit::signed-64>>, {last, start + duration}}

        {_, start, duration, _, _, _, _}, {last, last_hit} ->
          {<<start + duration - last::signed-64>>, {start + duration, last_hit}}
      end)

    columns = [
      <<length(records)::32, Enum.count(records, &elem(&1, 1))::32, length(mnemonics)::32,
        length(labels)::32>>,
      for({key, start, _, _, _, _, _} <- records, start != nil, do: key),
      ends,
      for({_, _, duration, _, _, _, _} <- records, do: <<duration::64>>),
      for({_, _, _, m, _, _, _} <- records, do: <<Map.fetch!(mnemonic_ids, m)::16>>),
      for({_, _, _, _, l, _, _} <- records, do: <<Map.fetch!(label_ids, l)::32>>),
      for({_, start, _, _, _, hit?, _} <- records) do
        if(hit?, do: 1, else: 0) + if(start, do: 2, else: 0)
      end,
      seqs,
      Enum.map(mnemonics, &strz/1),
      Enum.map(labels, &strz/1)
    ]

    IO.iodata_to_binary([@version, :zstd.compress(columns, %{compressionLevel: 9})])
  end

  @doc "The records of a chunk made by `encode/1`."
  @spec decode(binary()) :: [action()]
  def decode(<<@version, compressed::binary>>) do
    <<n::32, nx::32, nm::32, nl::32, rest::binary>> =
      compressed |> :zstd.decompress() |> IO.iodata_to_binary()

    <<keys::binary-size(^nx * 8), rest::binary>> = rest

    <<ends::binary-size(^n * 8), durations::binary-size(^n * 8),
      mnemonic_ids::binary-size(^n * 2), label_ids::binary-size(^n * 4), flags::binary-size(^n),
      seqs::binary-size(^n * 8), strings::binary>> = rest

    {mnemonics, strings} = strings(strings, nm)
    {labels, ""} = strings(strings, nl)
    flags = for <<f <- flags>>, do: f
    durations = for <<d::64 <- durations>>, do: d

    {seqs, _} =
      Enum.map_reduce(for(<<d::signed-64 <- seqs>>, do: d), 0, fn d, last ->
        {last + d, last + d}
      end)

    {starts, _} =
      [flags, durations, for(<<e::signed-64 <- ends>>, do: e)]
      |> Enum.zip()
      |> Enum.map_reduce({0, 0}, fn
        {3, duration, delta}, {last, hit} -> {hit + delta - duration, {last, hit + delta}}
        {2, duration, delta}, {last, hit} -> {last + delta - duration, {last + delta, hit}}
        _, last -> {nil, last}
      end)

    {keys, <<>>} =
      Enum.map_reduce(flags, keys, fn
        f, <<key::binary-size(8), rest::binary>> when f >= 2 -> {key, rest}
        _, rest -> {@no_key, rest}
      end)

    [
      keys,
      starts,
      durations,
      for(<<m::16 <- mnemonic_ids>>, do: elem(mnemonics, m)),
      for(<<l::32 <- label_ids>>, do: elem(labels, l)),
      Enum.map(flags, &(rem(&1, 2) == 1)),
      seqs
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
