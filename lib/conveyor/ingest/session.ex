defmodule Conveyor.Ingest.Session do
  @moduledoc """
  The protocol of one build's event stream, as a pure module: the state of the stream plus
  an input give the new state plus a list of effects. No process, no database, no timer and
  no application environment; `Conveyor.Ingest.Worker` is the process that feeds the inputs
  and carries the effects out. (The only ambient reads are the wall clock inside
  `Normalizer.finalize/1` and `disconnect/1`, and `make_ref/0` for a batch's identity.)

  ## Interface

  A session is created with `new/2` and learns its row with `loaded/2`. After that every
  input returns `{session, effects}`:

  | Input | Meaning | Action of `docs/spec/Ingest.tla` |
  |---|---|---|
  | `loaded/2` | the invocation row was read (or belongs to another project) | `StartWorker` |
  | `push/4` | an `OrderedBuildEvent` arrived on a connection | `Push`: dedup, `Absorb`, takeover or reject |
  | `timer(s, :flush)` | the batch hold elapsed | `Flush` |
  | `committed/2` | the writer committed a batch | `Commit`, the fence held |
  | `failed/3` | a batch failed: `{:fenced, seq}`, a database error, `:writer_down` | `Commit` fenced, `DbFail` |
  | `writer_down/1` | the writer process went away | `DbFail` with the outcome unknown |
  | `timer(s, :idle)` | no event for `idle_timeout_ms` | (marks the build disconnected) |
  | `timer(s, :linger)` | the linger after the last commit elapsed | `Exit` |
  | `lifecycle/3` | attempt started / finished reached this node's live worker | `LifecycleStarted`, `LifecycleFinished` |
  | `timer(s, :broadcast)` | time to publish the coalesced digests | (not modelled) |

  ## Invariants a caller relies on

    * **Order.** Events are absorbed in sequence. A sequence at or below the committed one
      is acknowledged at once; one that is absorbed but not committed is acknowledged by
      its batch's commit, on the connection that resent it; one ahead of the expected
      sequence is refused (`{:error, :out_of_order}`) unless the session is quiet, in which
      case it asks for the row again (`:reload`) and judges the event against that.
    * **Acknowledgement is commit.** `{:ack, acker, seq}` is only ever emitted for a
      sequence the row holds, from `committed/2`; a resend at or below the committed
      sequence gets `{:ack_again, acker, seq}` (the same promise, told apart so that its
      near-zero latency stays out of the ack histogram). Acks of one batch are emitted in ascending order.
    * **Every waiter hears.** A failed batch fails everything in hand: every connection
      waiting on any batch (in flight or still open) gets `{:nack, acker, seq, reason}`,
      every blocked or waiting caller gets a reply, and the session stops. It never
      continues after a failure: the outcome may be unknown (`:writer_down`), so the next
      session starts from the row.
    * **Back-pressure.** When more than `max_unacked_events` are absorbed and not
      committed, the push is not replied to until the next commit.
    * **Quiet exit.** `{:stop, :normal}` after the linger is only emitted with nothing
      buffered, nothing at the writer and nobody waiting; a linger that elapses earlier
      waits for that.
    * **Finalize once.** The batch that carries the end-of-stream marker carries the final
      status; nothing after it finalizes again. An idle disconnect is not the end of the
      stream: the next event resumes the build (from the row once the disconnect has
      committed) and the marker still finalizes it.

  ## Effects

      {:reply, from, term}            answer a caller (GenServer.reply)
      {:ack, acker, seq}              the sequence is committed; tell the connection
      {:ack_again, acker, seq}        a resend of a sequence committed earlier; tell the connection
      {:nack, acker, seq, reason}     the sequence will not be acknowledged by this session
      {:submit, batch}                hand a batch to the writer (outcome: committed/failed)
      {:arm, name, ms}                (re)start the named timer: :flush :idle :linger :broadcast :refusal
      {:cancel, name}                 cancel the named timer
      :reload                         read the row again and call loaded/2
      :unregister                     give the session's name up (refused: wrong project)
      {:broadcast, topic, message}    publish on PubSub
      {:telemetry, event, measurements, metadata}
      {:log, level, message}
      {:finalized, invocation}        the build is final and references a fetchable profile
      :hibernate                      a quiet moment: compact the process
      {:stop, :normal}                the session is over
  """

  alias Conveyor.Bep.Event
  alias Conveyor.Ingest
  alias Conveyor.Ingest.{Batch, Normalizer, Scrub}
  alias Conveyor.Ingest.Session.Config
  alias Conveyor.Invocations
  alias Google.Devtools.Build.V1, as: V1

  # Columns a session holds only until the build is finalized and never puts on list topics.
  @wide_columns [:options, :workspace_status, :configurations]

  defstruct config: %Config{},
            invocation_id: nil,
            project_id: nil,
            norm_opts: [],
            # :loading | :live | {:refused, reason}
            phase: :loading,
            day: nil,
            norm: nil,
            batch: nil,
            expected_seq: 1,
            committed_seq: 0,
            inflight: %{},
            blocked: [],
            # The end-of-stream marker was absorbed (or the row says so).
            stream_finished: false,
            # The batch carrying the final status was handed to the writer.
            finalizing: false,
            # That batch, or an idle disconnect, committed.
            finalized: false,
            # An idle disconnect was submitted and no event has arrived since.
            disconnected: false,
            # :off | :armed | :due (elapsed with work in hand: stop when it drains)
            linger: :off,
            flush_armed: false,
            broadcast_armed: false,
            dirty: %{summary: false, targets: %{}, tests: %{}, actions: [], log: []},
            # A push waiting for the row to be read again: {obe, acker, from}
            pending: nil

  @type t :: %__MODULE__{}
  @type acker :: pid()
  @type from :: GenServer.from()
  @type timer :: :flush | :idle | :linger | :broadcast | :refusal
  @type effect ::
          {:reply, from(), term()}
          | {:ack, acker(), pos_integer()}
          | {:ack_again, acker(), pos_integer()}
          | {:nack, acker(), pos_integer(), term()}
          | {:submit, Batch.t()}
          | {:arm, timer(), non_neg_integer()}
          | {:cancel, timer()}
          | :reload
          | :unregister
          | {:broadcast, String.t(), term()}
          | {:telemetry, [atom()], map(), map()}
          | {:log, Logger.level(), String.t()}
          | {:finalized, map()}
          | :hibernate
          | {:stop, :normal}
  @type result :: {t(), [effect()]}

  @doc """
  A session for one invocation of one project, not yet loaded. Options: `:invocation_id`,
  `:project_id` (required), `:keywords`, `:api_key_tags`, `:max_log_bytes`.
  """
  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts) do
    %__MODULE__{
      config: config,
      invocation_id: Keyword.fetch!(opts, :invocation_id),
      project_id: Keyword.fetch!(opts, :project_id),
      norm_opts: Keyword.take(opts, [:keywords, :api_key_tags, :max_log_bytes])
    }
  end

  @doc """
  The row was read: at start, or after a `:reload`. Everything the session held is replaced
  by the row's view (it only asks for a reload when it holds nothing), every timer starts
  over, and a push that waited for the reload is judged against the fresh state. A row of
  another project (`{:error, reason}`) refuses the session: it gives its name up, answers
  its callers with the error for `refusal_ms` and stops.
  """
  @spec loaded(t(), {:ok, map()} | {:error, term()}) :: result()
  def loaded(%__MODULE__{} = s, {:error, reason}) do
    fx =
      case s.pending do
        {_obe, _acker, from} -> [{:reply, from, {:error, reason}}]
        nil -> []
      end

    {%{s | phase: {:refused, reason}, pending: nil},
     [:unregister, {:arm, :refusal, s.config.refusal_ms} | fx]}
  end

  def loaded(%__MODULE__{pending: pending} = s, {:ok, inv}) do
    day = Invocations.day(inv)

    fresh = %{
      s
      | phase: :live,
        day: day,
        norm: Normalizer.new(inv, s.norm_opts),
        expected_seq: inv.last_event_seq + 1,
        committed_seq: inv.last_event_seq,
        batch:
          Batch.new(
            s.invocation_id,
            s.project_id,
            day,
            inv.last_event_seq + 1,
            inv.log_bytes,
            inv.log_lines
          ),
        inflight: %{},
        blocked: [],
        stream_finished: inv.stream_finished,
        finalizing: inv.stream_finished,
        finalized: inv.stream_finished,
        disconnected: false,
        linger: :off,
        flush_armed: false,
        broadcast_armed: false,
        dirty: fresh_dirty(),
        pending: nil
    }

    acc =
      {fresh,
       [
         {:arm, :idle, s.config.idle_timeout_ms},
         {:cancel, :broadcast},
         {:cancel, :linger},
         {:cancel, :flush}
       ]}

    # A session for an already finished build (a late duplicate after a restart) only
    # answers what arrives during the linger.
    acc = if fresh.finalized, do: arm_linger(acc), else: acc
    acc = mark_summary(acc)

    case pending do
      {obe, acker, from} -> acc |> accept(obe, acker, from, false) |> done()
      nil -> done(acc)
    end
  end

  @doc """
  An event of the stream arrived on the connection whose acknowledgements go to `acker`.
  `from` is replied to once the event is accepted (later under back-pressure) or refused.
  """
  @spec push(t(), V1.OrderedBuildEvent.t(), acker(), from()) :: result()
  def push(%__MODULE__{phase: {:refused, reason}} = s, _obe, _acker, from),
    do: refuse(s, reason, from)

  def push(%__MODULE__{phase: :live} = s, %V1.OrderedBuildEvent{} = obe, acker, from) do
    {s, [{:arm, :idle, s.config.idle_timeout_ms}]} |> accept(obe, acker, from, true) |> done()
  end

  @doc """
  A lifecycle notification reached the node of this session. The attempt-started one
  changes nothing (the row exists). The attempt-finished one is committed through the
  fence and `from` is replied to with the outcome of that batch.
  """
  @spec lifecycle(t(), :invocation_attempt_started | :invocation_attempt_finished, from()) ::
          result()
  def lifecycle(%__MODULE__{phase: {:refused, reason}} = s, _kind, from),
    do: refuse(s, reason, from)

  def lifecycle(%__MODULE__{} = s, :invocation_attempt_started, from),
    do: {s, [{:reply, from, :ok}]}

  def lifecycle(%__MODULE__{} = s, :invocation_attempt_finished, from) do
    s = %{
      s
      | norm: Normalizer.set(s.norm, %{lifecycle_finished: true}),
        batch: Batch.add_waiter(s.batch, {:reply, from}, nil)
    }

    {s, []} |> flush() |> done()
  end

  @doc "The writer committed the batch `ref`."
  @spec committed(t(), reference()) :: result()
  def committed(%__MODULE__{} = s, ref) do
    case Map.pop(s.inflight, ref) do
      {nil, _} ->
        {s, []}

      {batch, inflight} ->
        telemetry =
          {:telemetry, [:conveyor, :ingest, :batch, :committed],
           %{events: Batch.event_count(batch)}, %{invocation_id: s.invocation_id}}

        s = %{s | inflight: inflight, committed_seq: max(s.committed_seq, batch.last_seq)}
        acc = {s, [telemetry | notify(batch, :ok, [])]} |> unblock()

        {s, _} =
          acc =
          if batch.finalize and (s.stream_finished or s.disconnected),
            do: finalized(acc),
            else: acc

        cond do
          s.linger == :due and quiet?(s) -> acc |> stop() |> done()
          # A finished session with nothing in hand only lingers: compact it now. The
          # broadcast tick does the same, but a commit that lands after the last tick (the
          # final batch under load, or the attempt-finished notification that wakes a
          # hibernated session) would leave the heap and the event binaries it references
          # in place for the whole linger.
          s.finalized and quiet?(s) -> acc |> hibernate() |> done()
          true -> done(acc)
        end
    end
  end

  @doc """
  A batch failed. Later batches cannot commit before it (the fence), and the outcome of
  what the writer held may be unknown, so everything in hand fails with it and the session
  stops: the client resends from its last acknowledgement and the next session starts
  from the row, which acknowledges whatever did commit.
  """
  @spec failed(t(), reference() | nil, term()) :: result()
  def failed(%__MODULE__{} = s, _ref, reason) do
    fx =
      s.inflight
      |> Map.values()
      |> Enum.sort_by(& &1.first_seq)
      |> Kernel.++([s.batch])
      |> Enum.reduce([], &notify(&1, {:error, reason}, &2))

    fx = Enum.reduce(s.blocked, fx, &[{:reply, &1, {:error, reason}} | &2])

    log =
      {:log, :error, "invocation #{s.invocation_id}: batch commit failed: #{inspect(reason)}"}

    {%{s | inflight: %{}, blocked: [], batch: %{s.batch | waiters: []}}, [log | fx]}
    |> stop()
    |> done()
  end

  @doc "The writer process went away: a failure of whatever it held, if anything."
  @spec writer_down(t()) :: result()
  def writer_down(%__MODULE__{inflight: inflight} = s) when inflight == %{}, do: {s, []}
  def writer_down(%__MODULE__{} = s), do: failed(s, nil, :writer_down)

  @doc "The named timer elapsed (the caller only reports timers that are still armed)."
  @spec timer(t(), timer()) :: result()
  def timer(%__MODULE__{} = s, :refusal), do: {s, [{:stop, :normal}]}
  def timer(%__MODULE__{phase: {:refused, _}} = s, _name), do: {s, []}

  def timer(%__MODULE__{} = s, :flush), do: {%{s | flush_armed: false}, []} |> flush() |> done()

  def timer(%__MODULE__{} = s, :linger) do
    if quiet?(s), do: {s, [{:stop, :normal}]}, else: {%{s | linger: :due}, []}
  end

  # Nothing to do for a finished build; while a batch is at the writer its outcome comes
  # first (it always comes: see `writer_down/1`).
  def timer(%__MODULE__{finalized: true} = s, :idle), do: {s, []}

  def timer(%__MODULE__{inflight: inflight} = s, :idle) when inflight != %{},
    do: {s, [{:arm, :idle, s.config.idle_timeout_ms}]}

  def timer(%__MODULE__{} = s, :idle) do
    log =
      {:log, :info,
       "invocation #{s.invocation_id}: idle for #{s.config.idle_timeout_ms} ms, marking disconnected"}

    {changes, norm} = s.norm |> Normalizer.disconnect() |> Normalizer.take_dirty()
    batch = s.batch |> Batch.set_invocation(changes) |> Map.put(:finalize, true)

    {%{s | norm: norm, disconnected: true}, [log]}
    |> cancel_flush()
    |> submit(batch)
    |> done()
  end

  # A broadcast tick with nothing in hand is the quiet moment of a stream: between paced
  # events, and for the whole linger of a finished build. Hibernating there compacts the
  # heap and releases the event binaries the batches referenced (PLAN §24 item 5); a
  # finished session also drops the wide columns it will never read again.
  def timer(%__MODULE__{} = s, :broadcast) do
    {s, fx} = broadcast({%{s | broadcast_armed: false}, []})

    if s.inflight == %{} and Batch.empty?(s.batch),
      do: done({slim(s), [:hibernate | fx]}),
      else: done({s, fx})
  end

  @doc "The in-memory view of the invocation (what the digests carry)."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = s) do
    s.norm.inv
    |> Map.put(:id, s.invocation_id)
    |> Map.put(:project_id, s.project_id)
    |> Map.put(:last_event_seq, s.expected_seq - 1)
    |> Map.put(:finalized, s.finalized)
  end

  # --- one event ----------------------------------------------------------------------------

  # `may_reload?` is false for the push that already waited for a reload: it is judged
  # against the row as it is.
  defp accept(
         {s, fx},
         %V1.OrderedBuildEvent{sequence_number: seq} = obe,
         acker,
         from,
         may_reload?
       ) do
    cond do
      # Already committed (a resend after a retry): acknowledged at once.
      seq <= s.committed_seq ->
        {s, [{:ack_again, acker, seq}, {:reply, from, :ok} | fx]}

      # Absorbed but not committed: a client that reconnected to this node resends what it
      # never saw acknowledged. The ack must wait for the commit, on this connection;
      # acking now would let a failed commit lose the event for good (Ingest.tla,
      # Durability).
      seq < s.expected_seq ->
        {await_commit(s, seq, acker), [{:reply, from, :ok} | fx]}

      # Ahead. Behind a balancer a retried stream can land on a node whose session never
      # saw what another node committed: with nothing in hand it resumes from the row
      # instead of rejecting the sequence.
      seq > s.expected_seq and may_reload? and quiet?(s) ->
        {%{s | pending: {obe, acker, from}}, [:reload | fx]}

      seq > s.expected_seq ->
        log =
          {:log, :warning,
           "invocation #{s.invocation_id}: got seq #{seq}, expected #{s.expected_seq}"}

        {s, [{:reply, from, {:error, :out_of_order}}, log | fx]}

      # The client is back after an idle disconnect that committed: the session starts
      # again from the row, as a new one would (it may have dropped the wide columns).
      s.disconnected and s.finalized and may_reload? ->
        {%{s | pending: {obe, acker, from}}, [:reload | fx]}

      true ->
        # (Back before the disconnect committed: the session's own view is still current.)
        {s, fx} = absorb({%{s | disconnected: false}, fx}, obe)
        s = %{s | expected_seq: seq + 1, batch: Batch.add_waiter(s.batch, {:ack, acker}, seq)}
        {s, fx} = maybe_flush({s, fx})

        if s.expected_seq - 1 - s.committed_seq > s.config.max_unacked_events,
          do: {%{s | blocked: [from | s.blocked]}, fx},
          else: {s, [{:reply, from, :ok} | fx]}
    end
  end

  defp absorb({s, fx}, %V1.OrderedBuildEvent{sequence_number: seq, event: event}) do
    case Event.bes_kind(event) do
      :bazel_event ->
        case Event.unwrap(event) do
          {:ok, bep} ->
            {bep, changed?} = Scrub.event(bep)

            bytes =
              if changed?, do: BuildEventStream.BuildEvent.encode(bep), else: any_bytes(event)

            kind = bep |> Event.payload_kind() |> to_string()
            {norm, batch} = Normalizer.apply(s.norm, bep, seq, s.batch)
            batch = Batch.add_event(batch, seq, kind, bytes)
            mark_event({%{s | norm: norm, batch: batch}, fx}, bep)

          {:error, reason} ->
            log =
              {:log, :warning,
               "invocation #{s.invocation_id} ##{seq}: undecodable bazel_event #{inspect(reason)}"}

            {%{s | batch: Batch.add_marker(s.batch, seq)}, [log | fx]}
        end

      :component_stream_finished ->
        {%{s | stream_finished: true, batch: Batch.add_marker(s.batch, seq)}, fx}

      _other ->
        {%{s | batch: Batch.add_marker(s.batch, seq)}, fx}
    end
  end

  defp any_bytes(%V1.BuildEvent{event: {:bazel_event, %Google.Protobuf.Any{value: bytes}}}),
    do: bytes

  # Registers `acker` for the ack of an absorbed, uncommitted sequence: on the batch still
  # being built, or on the in-flight batch that carries it.
  defp await_commit(s, seq, acker) do
    if seq >= s.batch.first_seq do
      %{s | batch: Batch.add_waiter(s.batch, {:ack, acker}, seq)}
    else
      case Enum.find(s.inflight, fn {_ref, b} -> seq >= b.first_seq and seq <= b.last_seq end) do
        {ref, b} -> put_in(s.inflight[ref], Batch.add_waiter(b, {:ack, acker}, seq))
        nil -> s
      end
    end
  end

  # --- batches ------------------------------------------------------------------------------

  defp maybe_flush({s, fx} = acc) do
    cond do
      Batch.event_count(s.batch) >= s.config.batch_max_events -> flush(acc)
      s.batch.event_bytes + s.batch.log_bytes >= s.config.batch_max_bytes -> flush(acc)
      s.stream_finished -> flush(acc)
      s.flush_armed -> acc
      true -> {%{s | flush_armed: true}, [{:arm, :flush, s.config.batch_flush_ms} | fx]}
    end
  end

  defp flush(acc) do
    {s, fx} = cancel_flush(acc)
    {s, batch, fx} = prepare(s, fx)

    if Batch.empty?(batch) and batch.waiters == [],
      do: {s, fx},
      else: submit({s, fx}, batch)
  end

  defp cancel_flush({%{flush_armed: true} = s, fx}),
    do: {%{s | flush_armed: false}, [{:cancel, :flush} | fx]}

  defp cancel_flush(acc), do: acc

  # Finalization happens in the batch that carries the end-of-stream marker, so the final
  # status and the last ack become durable together; it happens once (a lifecycle finish
  # that arrives while that batch is at the writer must not count the tags again).
  defp prepare(%{stream_finished: true, finalizing: false} = s, fx) do
    {norm, fx} = s.norm |> Normalizer.finalize() |> settle_profile(s.invocation_id, fx)
    {changes, norm} = Normalizer.take_dirty(norm)

    batch =
      s.batch
      |> Batch.set_invocation(changes)
      |> Batch.count_tags(norm.inv[:tags])
      |> Map.put(:finalize, true)

    {%{s | norm: norm, finalizing: true}, batch, fx}
  end

  defp prepare(s, fx) do
    {changes, norm} = Normalizer.take_dirty(s.norm)
    {%{s | norm: norm}, Batch.set_invocation(s.batch, changes), fx}
  end

  # A profile Bazel wrote to a local file (the default without a remote cache) can never be
  # fetched: record that in the final batch instead of a read and an update per build
  # after the commit. Fetchable references are handled after the commit (`:finalized`).
  defp settle_profile(%{inv: %{profile_status: "referenced", profile_uri: uri}} = norm, id, fx)
       when is_binary(uri) do
    case Conveyor.Artifacts.Resource.parse_uri(uri) do
      {:ok, _} ->
        {norm, fx}

      {:error, reason} ->
        log = {:log, :info, "invocation #{id}: profile unavailable: #{inspect(reason)}"}
        {Normalizer.set(norm, %{profile_status: "unavailable"}), [log | fx]}
    end
  end

  defp settle_profile(norm, _id, fx), do: {norm, fx}

  # The batch goes to the writer and a fresh one starts where it ended.
  defp submit({s, fx}, batch) do
    next =
      Batch.new(
        s.invocation_id,
        s.project_id,
        s.day,
        s.expected_seq,
        s.norm.inv[:log_bytes],
        s.norm.inv[:log_lines]
      )

    {%{s | batch: next, inflight: Map.put(s.inflight, batch.ref, batch)}, [{:submit, batch} | fx]}
  end

  # The build is final (or disconnected) in the row.
  defp finalized({s, fx}) do
    # Only a build that referenced a profile on a remote cache has work to schedule; the
    # session's own view of the row saves the read.
    fx =
      if s.norm.inv[:profile_status] == "referenced",
        do: [{:finalized, s.norm.inv} | fx],
        else: fx

    {%{s | finalized: true}, fx} |> mark_summary() |> arm_linger()
  end

  # Waiters are stored newest-first; acks go out in ascending sequence order (`fx` is
  # reversed at the end).
  defp notify(%Batch{waiters: waiters}, outcome, fx) do
    waiters
    |> Enum.reverse()
    |> Enum.reduce(fx, fn
      {{:reply, from}, _seq}, fx -> [{:reply, from, outcome} | fx]
      {{:ack, pid}, seq}, fx when outcome == :ok -> [{:ack, pid, seq} | fx]
      {{:ack, pid}, seq}, fx -> [{:nack, pid, seq, elem(outcome, 1)} | fx]
    end)
  end

  defp unblock({%{blocked: []}, _fx} = acc), do: acc

  defp unblock({s, fx}),
    do: {%{s | blocked: []}, Enum.reduce(s.blocked, fx, &[{:reply, &1, :ok} | &2])}

  # --- ending -------------------------------------------------------------------------------

  defp arm_linger({%{linger: :off} = s, fx}),
    do: {%{s | linger: :armed}, [{:arm, :linger, s.config.linger_ms} | fx]}

  defp arm_linger(acc), do: acc

  # A session exits only when it is quiet (`Exit` in Ingest.tla).
  defp quiet?(s),
    do: s.inflight == %{} and s.blocked == [] and Batch.empty?(s.batch) and s.batch.waiters == []

  defp stop({s, fx}), do: {s, [{:stop, :normal} | fx]}
  defp hibernate({s, fx}), do: {s, [:hibernate | fx]}

  defp refuse(s, reason, from),
    do: {s, [{:reply, from, {:error, reason}}, {:arm, :refusal, s.config.refusal_ms}]}

  defp done({s, fx}), do: {s, Enum.reverse(fx)}

  # --- digests ------------------------------------------------------------------------------

  defp fresh_dirty, do: %{summary: false, targets: %{}, tests: %{}, actions: [], log: []}

  defp mark_summary({s, fx}), do: arm_broadcast({%{s | dirty: %{s.dirty | summary: true}}, fx})

  defp mark_event({s, fx}, %BuildEventStream.BuildEvent{payload: {kind, payload}}) do
    dirty = s.dirty

    dirty =
      case kind do
        :progress ->
          %{dirty | log: [payload.stdout <> payload.stderr | dirty.log]}

        k when k in [:configured, :completed, :test_summary, :target_summary] ->
          %{dirty | targets: Map.merge(dirty.targets, s.batch.targets), summary: true}

        :test_result ->
          %{dirty | tests: Map.merge(dirty.tests, s.batch.tests), summary: true}

        :action ->
          %{dirty | actions: Enum.take(s.batch.actions, 1) ++ dirty.actions, summary: true}

        _ ->
          %{dirty | summary: true}
      end

    arm_broadcast({%{s | dirty: dirty}, fx})
  end

  defp arm_broadcast({%{broadcast_armed: false} = s, fx}),
    do: {%{s | broadcast_armed: true}, [{:arm, :broadcast, s.config.broadcast_interval_ms} | fx]}

  defp arm_broadcast(acc), do: acc

  defp broadcast({%{dirty: dirty} = s, fx}) do
    id = s.invocation_id

    fx =
      if dirty.summary do
        # List pages render a row per build: the wide columns (options, workspace status,
        # configurations) are tens of KB each and stay out of list-level messages. With a
        # watched project of thousands of live builds, every session's tick lands on the
        # viewer's node (fleet test: a 16 GB node killed within a minute).
        message = {:invocation_updated, s |> summary() |> Map.drop(@wide_columns)}

        [
          {:broadcast, Ingest.all_topic(), message},
          {:broadcast, Ingest.project_topic(s.project_id), message} | fx
        ]
      else
        fx
      end

    fx =
      if dirty.summary or dirty.targets != %{} or dirty.tests != %{} or dirty.actions != [] do
        detail = %{
          invocation: summary(s),
          targets: Map.values(dirty.targets),
          tests: Map.values(dirty.tests),
          actions: Enum.reverse(dirty.actions)
        }

        [{:broadcast, Ingest.invocation_topic(id), {:invocation_detail, detail}} | fx]
      else
        fx
      end

    fx =
      if dirty.log != [] do
        # Byte offset of these chunks in the stored log, so a viewer that loaded the log
        # over HTTP can splice live appends exactly.
        offset = max((s.norm.inv[:log_bytes] || 0) - IO.iodata_length(dirty.log), 0)
        [{:broadcast, Ingest.log_topic(id), {:log_chunks, Enum.reverse(dirty.log), offset}} | fx]
      else
        fx
      end

    {%{s | dirty: fresh_dirty()}, fx}
  end

  defp slim(%{finalized: true} = s), do: update_in(s.norm.inv, &Map.drop(&1, @wide_columns))
  defp slim(s), do: s
end
