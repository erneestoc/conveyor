defmodule Conveyor.Ingest.Normalizer do
  @moduledoc """
  Pure translation of decoded BEP events into invocation state and batch rows.

  `apply/4` takes the current `State`, a decoded `BuildEventStream.BuildEvent`, its
  sequence number and the current `Batch`, and returns the updated pair. It never touches
  the database, which keeps it trivially unit-testable against recorded fixtures.
  """

  alias BuildEventStream, as: BES
  alias Conveyor.Bep.Event
  alias Conveyor.Ingest.{Batch, Status, Tags}

  defmodule State do
    @moduledoc "In-memory view of the invocation row plus what changed since the last commit."
    defstruct inv: %{},
              dirty: MapSet.new(),
              tag_sources: %{},
              finished_seen: false,
              aborted_seen: false

    @type t :: %__MODULE__{}
  end

  @type state :: State.t()

  @counter_fields ~w(targets_configured targets_completed targets_failed tests_total tests_passed tests_failed tests_flaky tests_timed_out actions_failed event_count log_bytes log_lines)a

  @doc "Builds a state from an invocation row (a struct or map)."
  @spec new(map(), keyword()) :: state()
  def new(inv, opts \\ []) do
    inv = inv |> to_plain_map() |> Map.take(Conveyor.Invocations.Invocation.__schema__(:fields))

    %State{
      inv: inv,
      # A rehydrated worker (restart or takeover) must remember verdicts already committed.
      finished_seen: inv[:exit_code_name] != nil,
      aborted_seen: inv[:abort_reason] != nil,
      tag_sources: %{
        keywords: Tags.from_keywords(Keyword.get(opts, :keywords, [])),
        api_key: Keyword.get(opts, :api_key_tags, %{}),
        derived: derived_tags(inv)
      }
    }
  end

  @doc "Sets fields on the in-memory invocation and marks them dirty."
  @spec set(state(), map()) :: state()
  def set(%State{} = state, changes) when changes == %{}, do: state

  def set(%State{} = state, changes) do
    %{
      state
      | inv: Map.merge(state.inv, changes),
        dirty: MapSet.union(state.dirty, MapSet.new(Map.keys(changes)))
    }
  end

  @doc "Returns the dirty fields as a map and clears the dirty set."
  @spec take_dirty(state()) :: {map(), state()}
  def take_dirty(%State{} = state) do
    {Map.take(state.inv, MapSet.to_list(state.dirty)), %{state | dirty: MapSet.new()}}
  end

  @spec apply(state(), BES.BuildEvent.t(), pos_integer(), Batch.t()) :: {state(), Batch.t()}
  def apply(%State{} = state, %BES.BuildEvent{} = event, seq, %Batch{} = batch) do
    state = increment(state, :event_count)
    handle(Event.payload_kind(event), event, seq, state, batch)
  end

  # --- per payload ------------------------------------------------------------------------

  defp handle(:started, %{payload: {:started, s}}, _seq, state, batch) do
    state =
      set(state, %{
        command: blank_to_nil(s.command),
        bazel_version: blank_to_nil(s.build_tool_version),
        options_description: blank_to_nil(s.options_description),
        cwd: blank_to_nil(s.working_directory),
        workspace: blank_to_nil(s.workspace_directory),
        host: blank_to_nil(s.host) || state.inv[:host],
        user_name: blank_to_nil(s.user) || state.inv[:user_name],
        started_at: Event.to_datetime(s.start_time) || state.inv[:started_at]
      })

    {retag(state, :derived, derived_tags(state.inv)), batch}
  end

  defp handle(:build_metadata, %{payload: {:build_metadata, m}}, _seq, state, batch) do
    {retag(state, :metadata, m.metadata), batch}
  end

  defp handle(:workspace_status, %{payload: {:workspace_status, ws}}, _seq, state, batch) do
    items = Map.new(ws.item, &{&1.key, &1.value})

    state =
      set(state, %{
        workspace_status: items,
        user_name: state.inv[:user_name] || blank_to_nil(items["BUILD_USER"]),
        host: state.inv[:host] || blank_to_nil(items["BUILD_HOST"])
      })

    state = retag(state, :derived, derived_tags(state.inv))
    {retag(state, :workspace_status, items), batch}
  end

  defp handle(
         :unstructured_command_line,
         %{payload: {:unstructured_command_line, cl}},
         _seq,
         state,
         batch
       ) do
    {set_option(state, "unstructured", cl.args), batch}
  end

  defp handle(
         :structured_command_line,
         %{payload: {:structured_command_line, cl}},
         _seq,
         state,
         batch
       ) do
    sections =
      Enum.map(cl.sections, fn section ->
        case section.section_type do
          {:chunk_list, %{chunk: chunks}} ->
            %{"label" => section.section_label, "chunks" => chunks}

          {:option_list, %{option: options}} ->
            %{"label" => section.section_label, "options" => Enum.map(options, &option_map/1)}

          _ ->
            %{"label" => section.section_label}
        end
      end)

    {set_option(state, "structured." <> cl.command_line_label, sections), batch}
  end

  defp handle(:options_parsed, %{payload: {:options_parsed, op}}, _seq, state, batch) do
    parsed = %{
      "startup" => op.startup_options,
      "explicit_startup" => op.explicit_startup_options,
      "cmd_line" => op.cmd_line,
      "explicit_cmd_line" => op.explicit_cmd_line,
      "tool_tag" => op.tool_tag
    }

    {set_option(state, "parsed", parsed), batch}
  end

  defp handle(:expanded, %{id: %{id: {:pattern, %{pattern: patterns}}}}, _seq, state, batch) do
    {set(state, %{patterns: Enum.uniq(state.inv[:patterns] ++ patterns)}), batch}
  end

  defp handle(
         :configuration,
         %{id: %{id: {:configuration, %{id: id}}}, payload: {:configuration, c}},
         _seq,
         state,
         batch
       ) do
    conf = %{
      "mnemonic" => c.mnemonic,
      "platform" => c.platform_name,
      "cpu" => c.cpu,
      "is_tool" => c.is_tool
    }

    {set(state, %{configurations: Map.put(state.inv[:configurations], id, conf)}), batch}
  end

  defp handle(
         :configured,
         %{id: %{id: {:target_configured, tid}}, payload: {:configured, c}},
         _seq,
         state,
         batch
       ) do
    attrs = %{
      label: tid.label,
      aspect: tid.aspect || "",
      kind: blank_to_nil(c.target_kind),
      test_size: size(c.test_size),
      status: "configured",
      first_seen_at: DateTime.utc_now()
    }

    {increment(state, :targets_configured), Batch.upsert_target(batch, target_key(attrs), attrs)}
  end

  defp handle(
         :named_set_of_files,
         %{id: %{id: {:named_set, %{id: set_id}}}, payload: {:named_set_of_files, ns}},
         _seq,
         state,
         batch
       ) do
    attrs = %{
      set_id: set_id,
      files: %{"files" => Enum.map(ns.files, &file_map/1)},
      child_set_ids: Enum.map(ns.file_sets, & &1.id)
    }

    {state, Batch.add_named_set(batch, attrs)}
  end

  defp handle(
         :completed,
         %{id: %{id: {:target_completed, tid}}, payload: {:completed, c}},
         _seq,
         state,
         batch
       ) do
    attrs = %{
      label: tid.label,
      configuration_id: configuration_id(tid.configuration),
      aspect: tid.aspect || "",
      status: if(c.success, do: "success", else: "failed"),
      failure_message: failure_message(c.failure_detail),
      output_groups: %{
        "groups" =>
          Enum.map(
            c.output_group,
            &%{
              "name" => &1.name,
              "file_sets" => Enum.map(&1.file_sets, fn fs -> fs.id end),
              "incomplete" => &1.incomplete
            }
          )
      },
      completed_at: DateTime.utc_now()
    }

    attrs = if c.target_kind != "", do: Map.put(attrs, :kind, c.target_kind), else: attrs

    state =
      state
      |> increment(:targets_completed)
      |> then(&if(c.success, do: &1, else: increment(&1, :targets_failed)))

    {state, Batch.upsert_target(batch, target_key(attrs), attrs)}
  end

  defp handle(
         :action,
         %{id: %{id: {:action_completed, aid}}, payload: {:action, a}},
         seq,
         state,
         batch
       ) do
    started = Event.to_datetime(a.start_time)
    ended = Event.to_datetime(a.end_time)

    attrs = %{
      seq: seq,
      label: blank_to_nil(a.label) || blank_to_nil(aid.label),
      configuration_id:
        configuration_id(a.configuration) |> blank_to_nil() || configuration_id(aid.configuration),
      mnemonic: blank_to_nil(a.type),
      success: a.success,
      exit_code: a.exit_code,
      started_at: started,
      ended_at: ended,
      duration_ms: duration_ms(started, ended),
      primary_output: file_uri_or_name(a.primary_output) || blank_to_nil(aid.primary_output),
      stdout_uri: file_uri_or_name(a.stdout),
      stderr_uri: file_uri_or_name(a.stderr),
      command_line: a.command_line,
      failure_message: failure_message(a.failure_detail)
    }

    state = if a.success, do: state, else: increment(state, :actions_failed)
    {state, Batch.add_action(batch, attrs)}
  end

  defp handle(
         :test_result,
         %{id: %{id: {:test_result, tid}}, payload: {:test_result, r}},
         _seq,
         state,
         batch
       ) do
    info = r.execution_info

    attrs = %{
      label: tid.label,
      configuration_id: configuration_id(tid.configuration),
      run: tid.run,
      shard: tid.shard,
      attempt: tid.attempt,
      status: to_string(r.status),
      cached_locally: r.cached_locally,
      cached_remotely: (info && info.cached_remotely) || false,
      strategy: info && blank_to_nil(info.strategy),
      hostname: info && blank_to_nil(info.hostname),
      exit_code: info && info.exit_code,
      started_at: Event.to_datetime(r.test_attempt_start),
      duration_ms: Event.to_ms(r.test_attempt_duration),
      files: %{"files" => Enum.map(r.test_action_output, &file_map/1)},
      warnings: r.warning
    }

    {state,
     Batch.upsert_test(
       batch,
       {attrs.label, attrs.configuration_id, attrs.run, attrs.shard, attrs.attempt},
       attrs
     )}
  end

  defp handle(
         :test_summary,
         %{id: %{id: {:test_summary, tid}}, payload: {:test_summary, s}},
         _seq,
         state,
         batch
       ) do
    status = to_string(s.overall_status)

    attrs = %{
      label: tid.label,
      configuration_id: configuration_id(tid.configuration),
      aspect: "",
      test_status: status,
      duration_ms: Event.to_ms(s.total_run_duration)
    }

    counter =
      case s.overall_status do
        :PASSED -> :tests_passed
        :FLAKY -> :tests_flaky
        :TIMEOUT -> :tests_timed_out
        _ -> :tests_failed
      end

    state = state |> increment(:tests_total) |> increment(counter)
    {state, Batch.upsert_target(batch, target_key(attrs), attrs)}
  end

  defp handle(
         :target_summary,
         %{id: %{id: {:target_summary, tid}}, payload: {:target_summary, s}},
         _seq,
         state,
         batch
       ) do
    attrs = %{label: tid.label, configuration_id: configuration_id(tid.configuration), aspect: ""}

    attrs =
      if s.overall_test_status == :NO_STATUS,
        do: attrs,
        else: Map.put(attrs, :test_status, to_string(s.overall_test_status))

    {state, Batch.upsert_target(batch, target_key(attrs), attrs)}
  end

  defp handle(:progress, %{payload: {:progress, p}}, seq, state, batch) do
    text = p.stdout <> p.stderr

    if text == "" do
      {state, batch}
    else
      lines = text |> :binary.matches("\n") |> length()

      state =
        set(state, %{
          log_bytes: state.inv[:log_bytes] + byte_size(text),
          log_lines: state.inv[:log_lines] + lines
        })

      {state, Batch.add_log(batch, seq, text)}
    end
  end

  defp handle(:aborted, %{payload: {:aborted, a}}, _seq, state, batch) do
    state = %{state | aborted_seen: true}
    # Keep the first, most specific abort; later ones are usually cascades.
    if state.inv[:abort_reason] do
      {state, batch}
    else
      {set(state, %{
         abort_reason: to_string(a.reason),
         abort_description: blank_to_nil(a.description)
       }), batch}
    end
  end

  defp handle(:finished, %{payload: {:finished, f}}, _seq, state, batch) do
    name = f.exit_code && f.exit_code.name
    code = f.exit_code && f.exit_code.code
    finished_at = Event.to_datetime(f.finish_time) || DateTime.utc_now()
    started_at = state.inv[:started_at]

    state =
      set(%{state | finished_seen: true}, %{
        exit_code_name: name,
        exit_code: code,
        finished_at: finished_at,
        duration_ms: duration_ms(started_at, finished_at),
        status: Status.from_exit_code(name, code)
      })

    state =
      case failure_message(f.failure_detail) do
        nil -> state
        msg -> set(state, %{abort_description: state.inv[:abort_description] || msg})
      end

    {state, batch}
  end

  defp handle(:build_tool_logs, %{payload: {:build_tool_logs, t}}, _seq, state, batch) do
    logs = Map.new(t.log, &{&1.name, file_map(&1)})
    profile = Enum.find(t.log, &(&1.name in ["command.profile.gz", "command.profile.json"]))

    state =
      case profile && profile.file do
        {:uri, uri} -> set(state, %{profile_uri: uri, profile_status: "referenced"})
        _ -> state
      end

    {state, Batch.put_metrics(batch, %{tool_logs: logs})}
  end

  defp handle(:build_metrics, %{payload: {:build_metrics, m}}, _seq, state, batch) do
    as = m.action_summary
    timing = m.timing_metrics
    mem = m.memory_metrics
    net = m.network_metrics && m.network_metrics.system_network_stats
    runners = Map.new((as && as.runner_count) || [], &{&1.name, &1.count})
    cache = as && as.action_cache_statistics

    state =
      set(state, %{
        actions_created: as && as.actions_created,
        actions_executed: as && as.actions_executed,
        remote_cache_hits: runners["remote cache hit"] || (as && as.remote_cache_hits),
        remote_exec: runners["remote"],
        worker_exec: runners["worker"],
        local_exec: runners["local"],
        sandbox_exec:
          Enum.reduce(runners, 0, fn {name, count}, acc ->
            if String.ends_with?(name, "-sandbox"), do: acc + count, else: acc
          end),
        action_cache_hits: cache && cache.hits,
        action_cache_misses: cache && cache.misses,
        analysis_ms: timing && timing.analysis_phase_time_in_ms,
        execution_ms: timing && timing.execution_phase_time_in_ms,
        cpu_ms: timing && timing.cpu_time_in_ms,
        wall_ms: timing && timing.wall_time_in_ms,
        critical_path_ms: timing && Event.to_ms(timing.critical_path_time),
        peak_heap_bytes: mem && mem.peak_post_gc_heap_size,
        packages_loaded: m.package_metrics && m.package_metrics.packages_loaded,
        bytes_sent: net && net.bytes_sent,
        bytes_recv: net && net.bytes_recv
      })

    {state, Batch.put_metrics(batch, %{build_metrics: to_json_map(m)})}
  end

  defp handle(:workspace_info, %{payload: {:workspace_info, w}}, _seq, state, batch) do
    {set(state, %{local_exec_root: blank_to_nil(w.local_exec_root)}), batch}
  end

  defp handle(_other, _event, _seq, state, batch), do: {state, batch}

  # --- finalization --------------------------------------------------------------------

  @doc """
  Final status once the stream has ended: keeps a `BuildFinished` verdict, otherwise
  aborted (if an `Aborted` event was seen) or unknown.
  """
  @spec finalize(state(), keyword()) :: state()
  def finalize(%State{} = state, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    status =
      cond do
        state.finished_seen -> state.inv[:status]
        state.aborted_seen -> "aborted"
        true -> "unknown"
      end

    finished_at = state.inv[:finished_at] || now

    set(state, %{
      status: status,
      stream_finished: true,
      finished_at: finished_at,
      duration_ms: state.inv[:duration_ms] || duration_ms(state.inv[:started_at], finished_at)
    })
  end

  @doc "Marks the invocation disconnected (idle timeout without a finished stream)."
  @spec disconnect(state()) :: state()
  def disconnect(%State{} = state) do
    if Status.final?(state.inv[:status]) do
      state
    else
      now = DateTime.utc_now()

      set(state, %{
        status: "disconnected",
        finished_at: now,
        duration_ms: duration_ms(state.inv[:started_at], now)
      })
    end
  end

  # --- helpers -----------------------------------------------------------------------------

  defp retag(state, source, tags) do
    sources = Map.put(state.tag_sources, source, tags)
    state = %{state | tag_sources: sources}
    merged = Tags.merge(sources)
    if merged == state.inv[:tags], do: state, else: set(state, %{tags: merged})
  end

  defp derived_tags(inv) do
    %{
      "command" => inv[:command],
      "bazel_version" => inv[:bazel_version],
      "host" => inv[:host],
      "user" => inv[:user_name]
    }
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp set_option(state, key, value),
    do: set(state, %{options: Map.put(state.inv[:options], key, value)})

  defp increment(state, field) when field in @counter_fields do
    set(state, %{field => (state.inv[field] || 0) + 1})
  end

  defp option_map(o) do
    %{
      "name" => o.option_name,
      "value" => o.option_value,
      "combined" => o.combined_form,
      "effect_tags" => Enum.map(o.effect_tags, &to_string/1)
    }
  end

  @doc false
  def file_map(%BES.File{} = f) do
    base = %{
      "name" => f.name,
      "path_prefix" => f.path_prefix,
      "digest" => blank_to_nil(f.digest),
      "length" => f.length
    }

    case f.file do
      {:uri, uri} ->
        Map.put(base, "uri", uri)

      {:contents, contents} ->
        Map.put(
          base,
          "contents",
          if(String.valid?(contents), do: contents, else: Base.encode64(contents))
        )

      {:symlink_target_path, path} ->
        Map.put(base, "symlink_target_path", path)

      _ ->
        base
    end
  end

  def file_map(nil), do: nil

  defp file_uri_or_name(nil), do: nil
  defp file_uri_or_name(%BES.File{file: {:uri, uri}}), do: uri
  defp file_uri_or_name(%BES.File{name: name}), do: blank_to_nil(name)

  defp failure_message(nil), do: nil
  defp failure_message(%{message: msg}), do: blank_to_nil(msg)

  defp configuration_id(nil), do: ""
  defp configuration_id(%{id: id}), do: id

  defp target_key(%{label: l, aspect: a}), do: {l, a}

  defp size(:UNKNOWN), do: nil
  defp size(size) when is_atom(size), do: size |> to_string() |> String.downcase()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp duration_ms(%DateTime{} = a, %DateTime{} = b), do: DateTime.diff(b, a, :millisecond)
  defp duration_ms(_, _), do: nil

  @doc false
  def to_json_map(struct), do: struct |> Protobuf.JSON.encode!() |> Jason.decode!()

  defp to_plain_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_plain_map(map) when is_map(map), do: map
end
