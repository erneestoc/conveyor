defmodule Conveyor.ExecLogBuilder do
  @moduledoc """
  Builds compact execution logs for tests out of the recorded fixtures
  (`test/fixtures/execlog/*.log.zst`): the fixture's entries are re-encoded under another
  invocation id with every spawn given a start and a duration, so several logs hold the
  same actions at chosen times (shards racing, a later duplicate, a cache hit).

  A spawn `i` of a log starts at `base + i × spacing` and runs for `duration` (execution
  and total time alike) unless `:each` changes it.
  """
  alias Conveyor.Bep.Fixture
  alias Tools.Protos.ExecLogEntry, as: Entry

  @clean Path.join([File.cwd!(), "test/fixtures/execlog/clean.log.zst"])

  def clean, do: @clean

  @doc "The decoded entries of a fixture."
  def entries(path \\ @clean) do
    path
    |> File.read!()
    |> :zstd.decompress()
    |> IO.iodata_to_binary()
    |> Fixture.frames()
    |> Enum.map(&Entry.decode/1)
  end

  @doc """
  A log (zstd) from fixture entries.

    * `:id` the invocation id (default: a new one)
    * `:base` the start of spawn 0 (a `DateTime`)
    * `:spacing` ms between spawn starts (default 1000), `:duration` ms (default 500)
    * `:each` `fn spawn, index -> spawn | nil`: last word on every spawn (nil drops it)
    * `:entries` other fixture entries than the clean log's
  """
  def log(opts) do
    base = Keyword.fetch!(opts, :base)
    spacing = Keyword.get(opts, :spacing, 1000)
    duration = Keyword.get(opts, :duration, 500)
    each = Keyword.get(opts, :each, fn spawn, _index -> spawn end)
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    {entries, _} =
      Enum.flat_map_reduce(Keyword.get(opts, :entries, entries()), 0, fn
        %{type: {:invocation, inv}} = e, i ->
          {[%{e | type: {:invocation, %{inv | id: id}}}], i}

        %{type: {:spawn, spawn}} = e, i ->
          spawn =
            spawn |> timed(DateTime.add(base, i * spacing, :millisecond), duration) |> each.(i)

          {if(spawn, do: [%{e | type: {:spawn, spawn}}], else: []), i + 1}

        e, i ->
          {[e], i}
      end)

    entries
    |> Enum.map(fn e ->
      bytes = Entry.encode(e)
      [Fixture.encode_varint(byte_size(bytes)), bytes]
    end)
    |> :zstd.compress()
    |> IO.iodata_to_binary()
  end

  @doc "Sets a spawn's start and its execution and total time."
  def timed(spawn, %DateTime{} = start, duration_ms) do
    us = DateTime.to_unix(start, :microsecond)
    d = duration(duration_ms)

    metrics = %{
      (spawn.metrics || %Tools.Protos.SpawnMetrics{})
      | start_time: %Google.Protobuf.Timestamp{
          seconds: div(us, 1_000_000),
          nanos: rem(us, 1_000_000) * 1000
        },
        total_time: d,
        execution_wall_time: d
    }

    %{spawn | metrics: metrics}
  end

  def duration(ms),
    do: %Google.Protobuf.Duration{seconds: div(ms, 1000), nanos: rem(ms, 1000) * 1_000_000}

  @doc "Makes a spawn a remote cache hit."
  def hit(spawn), do: %{spawn | cache_hit: true, runner: "remote cache hit"}

  @doc "Gives a spawn a Bazel action digest (as a remote or disk cache would)."
  def digest(spawn, text),
    do: %{
      spawn
      | digest: %Tools.Protos.Digest{
          hash: Base.encode16(:crypto.hash(:sha256, text), case: :lower),
          size_bytes: 140
        }
    }

  @doc "Gives a spawn platform (exec) properties."
  def platform(spawn, properties) do
    %{
      spawn
      | platform: %Tools.Protos.Platform{
          properties:
            Enum.map(properties, fn {k, v} ->
              %Tools.Protos.Platform.Property{name: k, value: v}
            end)
        }
    }
  end
end
