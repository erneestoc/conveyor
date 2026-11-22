defmodule Conveyor.ExecLog.Synth do
  @moduledoc """
  Writes compact execution logs (`--execution_log_compact_file`: zstd, varint-delimited
  `ExecLogEntry`) from a description of spawns, for the demo seed
  (`mix conveyor.seed --rbe-demo`) and the scale bench (`bench/rbe_scale.exs`). The logs
  go through the same upload and parse as Bazel's.

  A spawn is a map:

    * `:mnemonic`, `:target`, `:args` (list of strings)
    * `:inputs` `[{path, content hash}]`, `:output` `{path, content hash}`
    * `:start` (`DateTime`), `:ms` (execution and total time)
    * optional: `:hit` (a remote cache hit: no start, no time), `:digest` (hex action
      digest, as Bazel writes with a disk or remote cache; without it the parser computes
      its fallback key), `:platform` (`%{name => value}` exec properties), `:exit_code`,
      `:remotable`, `:cacheable` (both default true), `:runner`

  Files are interned once per `{path, hash}` and every spawn has its own input set, so the
  log's size is dominated by the input sets, as a real log's is.
  """
  alias Conveyor.Bep.Fixture
  alias Tools.Protos.ExecLogEntry, as: Entry

  @type spawn :: %{
          required(:mnemonic) => String.t(),
          required(:target) => String.t(),
          required(:args) => [String.t()],
          required(:inputs) => [{String.t(), String.t()}],
          required(:output) => {String.t(), String.t()},
          optional(atom()) => term()
        }

  @doc "The log (zstd) of one build."
  @spec encode(String.t(), [spawn()]) :: binary()
  def encode(invocation_id, spawns) do
    invocation =
      entry(
        0,
        {:invocation, %Entry.Invocation{hash_function_name: "SHA-256", id: invocation_id}}
      )

    {entries, _state} =
      Enum.map_reduce(spawns, {%{}, 1}, fn spawn, state ->
        {input_ids, new_inputs, state} = intern(spawn.inputs, state)
        {[output_id], new_output, {files, next}} = intern([spawn.output], state)
        set = entry(next, {:input_set, %Entry.InputSet{input_ids: input_ids}})

        {[new_inputs, new_output, set, entry(0, {:spawn, spawn_entry(spawn, next, output_id)})],
         {files, next + 1}}
      end)

    [invocation | entries]
    |> :zstd.compress()
    |> IO.iodata_to_binary()
  end

  # Files already written are referenced by id; new ones are written before their user.
  defp intern(files, state) do
    {ids, {new, files, next}} =
      Enum.map_reduce(files, {[], elem(state, 0), elem(state, 1)}, fn {path, hash} = file,
                                                                      {new, files, next} ->
        case files do
          %{^file => id} ->
            {id, {new, files, next}}

          _ ->
            e =
              entry(
                next,
                {:file,
                 %Entry.File{
                   path: path,
                   digest: %Tools.Protos.Digest{hash: hash, size_bytes: 1024}
                 }}
              )

            {next, {[e | new], Map.put(files, file, next), next + 1}}
        end
      end)

    {ids, Enum.reverse(new), {files, next}}
  end

  defp spawn_entry(spawn, input_set_id, output_id) do
    hit? = Map.get(spawn, :hit, false)

    %Entry.Spawn{
      args: spawn.args,
      platform: platform(Map.get(spawn, :platform)),
      input_set_id: input_set_id,
      outputs: [%Entry.Output{type: {:output_id, output_id}}],
      target_label: spawn.target,
      mnemonic: spawn.mnemonic,
      exit_code: Map.get(spawn, :exit_code, 0),
      runner:
        Map.get(spawn, :runner, if(hit?, do: "remote cache hit", else: "processwrapper-sandbox")),
      cache_hit: hit?,
      remotable: Map.get(spawn, :remotable, true),
      cacheable: Map.get(spawn, :cacheable, true),
      remote_cacheable: Map.get(spawn, :cacheable, true),
      digest: digest(Map.get(spawn, :digest)),
      metrics: if(hit?, do: nil, else: metrics(spawn.start, spawn.ms))
    }
  end

  defp platform(nil), do: nil

  defp platform(properties) do
    %Tools.Protos.Platform{
      properties:
        properties
        |> Enum.sort()
        |> Enum.map(fn {k, v} -> %Tools.Protos.Platform.Property{name: k, value: v} end)
    }
  end

  defp digest(nil), do: nil
  defp digest(hash), do: %Tools.Protos.Digest{hash: hash, size_bytes: 142}

  defp metrics(%DateTime{} = start, ms) do
    us = DateTime.to_unix(start, :microsecond)
    d = %Google.Protobuf.Duration{seconds: div(ms, 1000), nanos: rem(ms, 1000) * 1_000_000}

    %Tools.Protos.SpawnMetrics{
      start_time: %Google.Protobuf.Timestamp{
        seconds: div(us, 1_000_000),
        nanos: rem(us, 1_000_000) * 1000
      },
      total_time: d,
      execution_wall_time: d
    }
  end

  defp entry(id, type) do
    bytes = Entry.encode(%Entry{id: id, type: type})
    [Fixture.encode_varint(byte_size(bytes)), bytes]
  end

  @doc "A hex SHA-256 of a term's text: content hashes and action digests of made-up actions."
  @spec hash(iodata()) :: String.t()
  def hash(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
end
