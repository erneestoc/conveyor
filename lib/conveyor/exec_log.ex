defmodule Conveyor.ExecLog do
  @moduledoc """
  Bazel's compact execution log (`--execution_log_compact_file`): the inputs, outputs,
  cache status, runner and timings of every spawn. Uploaded as an artifact (any name
  matching `execution.log`, `*.execlog`, `exec_log.zst`…), parsed by
  `Conveyor.Workers.ParseExecLog` into `spawns`, and diffed against the previous build's
  spawns to explain why an action ran again.

  The format is zstd-compressed, varint-delimited `tools.protos.ExecLogEntry` messages
  (`priv/protos/bazel/src/main/protobuf/spawn.proto`). Files, directories and input sets
  are interned entries referenced by id; spawns point at an input set and a tool set.
  """
  import Ecto.Query

  alias Conveyor.ExecLog.Spawn
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo
  alias Tools.Protos.ExecLogEntry, as: Entry

  @name_re ~r/exec(ution)?[._-]?log/i
  @chunk 500

  @typedoc "A parsed spawn, ready to be stored."
  @type spawn :: map()

  @doc "True when an artifact name looks like an execution log."
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name), do: Regex.match?(@name_re, name)
  def name?(_), do: false

  # --- parsing -------------------------------------------------------------------------------

  @doc "Parses a compact execution log (zstd or raw) into spawns."
  @spec parse(binary()) ::
          {:ok, %{invocation_id: String.t() | nil, spawns: [spawn()]}} | {:error, term()}
  def parse(binary) when is_binary(binary) do
    with {:ok, entries} <- decode(binary) do
      table = Map.new(entries, &{&1.id, &1.type})

      invocation_id =
        Enum.find_value(entries, fn
          %{type: {:invocation, inv}} -> inv.id
          _ -> nil
        end)

      {spawns, _memo} =
        Enum.flat_map_reduce(entries, %{}, fn
          %{type: {:spawn, s}}, memo ->
            {row, memo} = spawn_row(s, table, memo)
            {[row], memo}

          _, memo ->
            {[], memo}
        end)

      {:ok, %{invocation_id: invocation_id, spawns: spawns}}
    end
  end

  defp decode(binary) do
    raw =
      try do
        binary |> :zstd.decompress() |> IO.iodata_to_binary()
      rescue
        _ -> binary
      end

    entries = raw |> Conveyor.Bep.Fixture.frames() |> Enum.map(&Entry.decode/1)

    if Enum.any?(entries, &match?(%{type: {:invocation, _}}, &1)),
      do: {:ok, entries},
      else: {:error, :not_an_execution_log}
  rescue
    _ -> {:error, :malformed}
  end

  # The stored path list is capped: `inputs_digest` and `input_files` cover every input,
  # so the verdict (same inputs or not) stays exact; only the per-path diff is bounded.
  @max_stored_inputs 50_000

  defp spawn_row(s, table, memo) do
    {inputs, memo} = expand(s.input_set_id, table, memo)
    {tools, memo} = expand(s.tool_set_id, table, memo)

    inputs =
      inputs
      |> merge_inputs(tools)
      |> Enum.map(fn {path, {digest, size}} -> {path, digest, size} end)
      |> Enum.sort()

    outputs = Enum.map(s.outputs, &output(&1.type, table))
    m = s.metrics

    row = %{
      target_label: s.target_label,
      mnemonic: s.mnemonic,
      primary_output: primary_output(outputs),
      cache_hit: s.cache_hit,
      runner: blank_to_nil(s.runner),
      exit_code: s.exit_code,
      status: blank_to_nil(s.status),
      remotable: s.remotable,
      cacheable: s.cacheable,
      remote_cacheable: s.remote_cacheable,
      total_ms: ms(m && m.total_time),
      exec_ms: ms(m && m.execution_wall_time),
      queue_ms: ms(m && m.queue_time),
      upload_ms: ms(m && m.upload_time),
      fetch_ms: ms(m && m.fetch_time),
      setup_ms: ms(m && m.setup_time),
      network_ms: ms(m && m.network_time),
      input_files: length(inputs),
      input_bytes:
        (m && m.input_bytes > 0 && m.input_bytes) || Enum.sum(Enum.map(inputs, &elem(&1, 2))),
      output_bytes: Enum.sum(Enum.map(outputs, & &1.size)),
      inputs_digest: digest_of(Enum.map(inputs, fn {p, d, _} -> [p, "\t", d] end)),
      outputs_digest: digest_of(Enum.map(outputs, &[&1.path, "\t", &1.digest])),
      outputs: %{
        "files" =>
          Enum.map(outputs, &%{"path" => &1.path, "digest" => &1.digest, "size" => &1.size})
      },
      inputs_blob:
        inputs
        |> Enum.take(@max_stored_inputs)
        |> Enum.map_join("\n", fn {p, d, _} -> p <> "\t" <> d end)
        |> compress()
    }

    {row, memo}
  end

  # Expands an interned entry into a map `path => {digest, size}`, memoized per id.
  #
  # Maps, not lists: input sets form a DAG in which the same file is reachable through many
  # paths (a test's runfiles reach a library's headers through every dependent), and
  # concatenating lists repeats every shared file once per path before `uniq` collapses
  # them. On the AWS trial that turned a 429-spawn abseil log (48k unique inputs) into 26
  # million list elements and minutes of parsing; a map union costs the smaller side.
  defp expand(0, _table, memo), do: {%{}, memo}

  defp expand(id, table, memo) do
    case memo do
      %{^id => cached} ->
        {cached, memo}

      _ ->
        {items, memo} = expand_entry(Map.get(table, id), table, memo)
        {items, Map.put(memo, id, items)}
    end
  end

  defp expand_entry({:file, f}, _table, memo),
    do: {%{f.path => {hash(f.digest), size(f.digest)}}, memo}

  defp expand_entry({:directory, %{path: path, files: []}}, _table, memo),
    do: {%{path => {"directory", 0}}, memo}

  defp expand_entry({:directory, %{path: path, files: files}}, _table, memo),
    do:
      {Map.new(files, fn f -> {path <> "/" <> f.path, {hash(f.digest), size(f.digest)}} end),
       memo}

  defp expand_entry({:unresolved_symlink, s}, _table, memo),
    do: {%{s.path => {"symlink:" <> s.target_path, 0}}, memo}

  defp expand_entry({:input_set, set}, table, memo),
    do: expand_many(set.input_ids ++ set.transitive_set_ids, table, memo)

  defp expand_entry({:symlink_entry_set, set}, table, memo),
    do: expand_many(Map.values(set.direct_entries) ++ set.transitive_set_ids, table, memo)

  defp expand_entry({:runfiles_tree, t}, table, memo) do
    {items, memo} = expand_many([t.input_set_id, t.symlinks_id, t.root_symlinks_id], table, memo)

    manifest =
      if t.repo_mapping_manifest && t.repo_mapping_manifest.digest,
        do: %{
          (t.path <> "/_repo_mapping") =>
            {hash(t.repo_mapping_manifest.digest), size(t.repo_mapping_manifest.digest)}
        },
        else: %{}

    {merge_inputs(items, manifest), memo}
  end

  defp expand_entry(_other, _table, memo), do: {%{}, memo}

  defp expand_many(ids, table, memo) do
    Enum.reduce(ids, {%{}, memo}, fn id, {acc, memo} ->
      {items, memo} = expand(id, table, memo)
      {merge_inputs(acc, items), memo}
    end)
  end

  # First occurrence wins, as the list version's uniq did.
  defp merge_inputs(acc, items) when map_size(acc) == 0, do: items
  defp merge_inputs(acc, items), do: Map.merge(items, acc)

  defp output({:output_id, id}, table) do
    case Map.get(table, id) do
      {:file, f} ->
        %{path: f.path, digest: hash(f.digest), size: size(f.digest)}

      {:directory, d} ->
        %{
          path: d.path,
          digest: digest_of(Enum.map(d.files, &[&1.path, "\t", hash(&1.digest)])),
          size: Enum.sum(Enum.map(d.files, &size(&1.digest)))
        }

      {:unresolved_symlink, s} ->
        %{path: s.path, digest: "symlink:" <> s.target_path, size: 0}

      _ ->
        %{path: "#" <> Integer.to_string(id), digest: "", size: 0}
    end
  end

  defp output({:invalid_output_path, path}, _table), do: %{path: path, digest: "", size: 0}

  # The first output Bazel actually produced identifies the action; test spawns list the
  # optional test.xml and friends first, as paths without contents.
  defp primary_output(outputs) do
    case Enum.find(outputs, &(&1.digest != "")) || List.first(outputs) do
      nil -> ""
      o -> o.path
    end
  end

  defp hash(nil), do: ""
  defp hash(%{hash: h}), do: h
  defp size(nil), do: 0
  defp size(%{size_bytes: s}), do: s

  defp ms(nil), do: nil
  defp ms(%{seconds: s, nanos: n}), do: s * 1000 + div(n, 1_000_000)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp digest_of(iodata) do
    iodata
    |> Enum.intersperse("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp compress(text), do: text |> :zstd.compress() |> IO.iodata_to_binary()

  @doc "The sorted `{path, digest}` inputs of a stored spawn."
  @spec inputs(Spawn.t()) :: [{String.t(), String.t()}]
  def inputs(%Spawn{id: id}) do
    blob = Repo.one!(from s in Spawn, where: s.id == ^id, select: s.inputs_blob)

    case blob |> :zstd.decompress() |> IO.iodata_to_binary() do
      "" ->
        []

      text ->
        text
        |> String.split("\n")
        |> Enum.map(fn line -> line |> String.split("\t", parts: 2) |> List.to_tuple() end)
    end
  end

  # --- storage -------------------------------------------------------------------------------

  @doc "Marks the log as uploaded and schedules parsing."
  @spec available(Invocation.t(), Conveyor.Blobs.Blob.t()) :: :ok
  def available(%Invocation{} = inv, _blob) do
    set_status(inv, "available")
    %{invocation_id: inv.id} |> Conveyor.Workers.ParseExecLog.new() |> Oban.insert!()
    :ok
  end

  @doc "Replaces the invocation's spawns with the parsed ones. Returns the count."
  @spec store!(Invocation.t(), %{spawns: [spawn()]}) :: non_neg_integer()
  def store!(%Invocation{id: id} = inv, %{spawns: spawns}) do
    now = DateTime.utc_now()
    rows = Enum.map(spawns, &(Map.put(&1, :invocation_id, id) |> Map.put(:inserted_at, now)))

    Repo.transaction(fn ->
      Repo.delete_all(from s in Spawn, where: s.invocation_id == ^id)
      Enum.each(Enum.chunk_every(rows, @chunk), &Repo.insert_all(Spawn, &1))
      set_status(inv, "parsed")
    end)

    length(rows)
  end

  @spec set_status(Invocation.t(), String.t()) :: :ok
  def set_status(%Invocation{id: id}, status) do
    Repo.update_all(from(i in Invocation, where: i.id == ^id), set: [exec_log_status: status])
    :ok
  end

  @doc "The spawns of an invocation in log order (without the inputs blob)."
  @spec list(Invocation.t() | String.t()) :: [Spawn.t()]
  def list(inv) do
    Repo.all(from s in Spawn, where: s.invocation_id == ^id(inv), order_by: s.id)
  end

  @doc "Counts for the overview: spawns, remote cache hits, executed, bytes."
  @spec summary(Invocation.t() | String.t()) :: map() | nil
  def summary(inv) do
    Repo.one(
      from s in Spawn,
        where: s.invocation_id == ^id(inv),
        select: %{
          spawns: count(s.id),
          cache_hits: fragment("count(*) FILTER (WHERE ?)", s.cache_hit),
          executed: fragment("count(*) FILTER (WHERE NOT ?)", s.cache_hit),
          input_bytes: sum(s.input_bytes),
          output_bytes: sum(s.output_bytes)
        }
    )
    |> case do
      %{spawns: 0} -> nil
      m -> %{m | input_bytes: to_int(m.input_bytes), output_bytes: to_int(m.output_bytes)}
    end
  end

  # --- explaining ----------------------------------------------------------------------------

  @typedoc """
  Why a spawn ran: `:cache_hit`; `:new` (the previous build did not run this action);
  `:inputs_changed` (with the diff); `:same_inputs` (identical inputs — a cache miss or a
  non-hermetic action; `outputs_changed?` tells which); `:no_previous` (no earlier build
  with an execution log to compare with).
  """
  @type explanation :: %{
          spawn: Spawn.t(),
          reason: :cache_hit | :new | :inputs_changed | :same_inputs | :no_previous,
          outputs_changed?: boolean() | nil,
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()]
        }

  @doc """
  Explains every spawn of a build against the previous build of the same project (same
  `branch` tag when the build has one) that has a parsed execution log.
  """
  @spec explain(Invocation.t()) :: %{
          previous: Invocation.t() | nil,
          rows: [explanation()],
          counts: map()
        }
  def explain(%Invocation{} = inv) do
    spawns = list(inv)
    previous = previous_with_log(inv)

    previous_by_key =
      if previous, do: Map.new(Enum.reverse(list(previous)), &{Spawn.key(&1), &1}), else: %{}

    rows =
      Enum.map(spawns, fn s ->
        base = %{
          spawn: s,
          reason: nil,
          outputs_changed?: nil,
          added: [],
          removed: [],
          changed: []
        }

        cond do
          s.cache_hit ->
            %{base | reason: :cache_hit}

          is_nil(previous) ->
            %{base | reason: :no_previous}

          true ->
            case Map.get(previous_by_key, Spawn.key(s)) do
              nil ->
                %{base | reason: :new}

              %Spawn{inputs_digest: d} = p when d == s.inputs_digest ->
                %{
                  base
                  | reason: :same_inputs,
                    outputs_changed?: p.outputs_digest != s.outputs_digest
                }

              p ->
                Map.merge(
                  %{
                    base
                    | reason: :inputs_changed,
                      outputs_changed?: p.outputs_digest != s.outputs_digest
                  },
                  diff(p, s)
                )
            end
        end
      end)

    %{previous: previous, rows: rows, counts: Enum.frequencies_by(rows, & &1.reason)}
  end

  @doc "Input paths added, removed and changed between two spawns."
  @spec diff(Spawn.t(), Spawn.t()) :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()]
        }
  def diff(%Spawn{} = before, %Spawn{} = after_) do
    old = Map.new(inputs(before))
    new = Map.new(inputs(after_))

    %{
      added: new |> Map.keys() |> Enum.reject(&Map.has_key?(old, &1)) |> Enum.sort(),
      removed: old |> Map.keys() |> Enum.reject(&Map.has_key?(new, &1)) |> Enum.sort(),
      changed: for({p, d} <- new, Map.has_key?(old, p), old[p] != d, do: p) |> Enum.sort()
    }
  end

  @doc "The most recent earlier build of the same project (and branch) with a parsed log."
  @spec previous_with_log(Invocation.t()) :: Invocation.t() | nil
  def previous_with_log(%Invocation{} = inv) do
    Invocation
    |> where([i], i.project_id == ^inv.project_id and i.id != ^inv.id)
    |> where([i], i.exec_log_status == "parsed" and i.inserted_at < ^inv.inserted_at)
    |> maybe_branch(inv.tags["branch"])
    |> order_by([i], desc: i.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_branch(query, nil), do: query

  defp maybe_branch(query, branch),
    do: where(query, [i], fragment("? ->> 'branch' = ?", i.tags, ^branch))

  defp id(%Invocation{id: id}), do: id
  defp id(id) when is_binary(id), do: id

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n), do: n
end
