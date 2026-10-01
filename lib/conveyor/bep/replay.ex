defmodule Conveyor.Bep.Replay do
  @moduledoc """
  Replays a recorded BEP fixture into a BES server exactly the way Bazel would:
  lifecycle events around a `PublishBuildToolEventStream` of `OrderedBuildEvent`s,
  each wrapped in a `google.protobuf.Any`, with a fresh invocation id so every replay is a
  new build. Used by tests, `mix conveyor.replay`, and the load generator.

  Like Bazel, the client survives a lost connection: when the stream errors, or no
  acknowledgement arrives for `:ack_timeout_ms` while events are outstanding (a connection
  that died silently behind a balancer), it dials a fresh connection to the next host and
  resends from the last acknowledged sequence number under the same invocation id, up to
  `:retries` times. Every reconnect emits `[:conveyor, :loadgen, :reconnect]`.
  """

  alias BuildEventStream.BuildEvent, as: BepEvent
  alias Conveyor.Bep.Fixture
  alias Google.Devtools.Build.V1, as: V1
  alias Google.Devtools.Build.V1.PublishBuildEvent.Stub

  @bep_type_url "type.googleapis.com/build_event_stream.BuildEvent"
  @default_ack_timeout_ms 30_000

  @type result :: %{
          invocation_id: String.t(),
          build_id: String.t(),
          sent: non_neg_integer(),
          acks: [non_neg_integer()],
          latencies_ms: [float()],
          duration_ms: non_neg_integer(),
          attempts: pos_integer()
        }

  @doc """
  Replays the events in `path` (or a list of decoded events) to a BES server.

  Options:
    * `:host`, `:port` — BES server (default `localhost:1985`); or `:hosts`, a list of
      `{host, port}` tried in turn on every reconnect, starting at `:host_offset`
    * `:api_key` — sent as the `x-api-key` header
    * `:invocation_id`, `:build_id` — default to fresh UUIDs
    * `:delay_ms` — pause between events (default 0)
    * `:lifecycle` — send lifecycle events (default true)
    * `:project_id` — value of `--bes_instance_name` (default "")
    * `:tls` — connect with TLS, verifying the server against the system CA store
    * `:retries` — reconnects allowed after a failed attempt (default 0); a retry resumes
      the same invocation from the last acknowledged event, as Bazel does
    * `:ack_timeout_ms` — give the connection up when events are outstanding and no
      acknowledgement arrived for this long (default #{@default_ack_timeout_ms})
    * `:drop_after` — simulate a connection loss: cancel the stream after this many events
      have been sent, then reconnect and resend everything from the first event (the
      client cannot know what was acked; the server acknowledges committed duplicates)
    * `:duplicate_every` — resend every n-th event, as Bazel does for events it believes
      unacknowledged
  """
  @spec run(Path.t() | [BepEvent.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(path_or_events, opts \\ [])

  def run(path, opts) when is_binary(path), do: run(Fixture.read!(path), opts)

  def run(events, opts) when is_list(events) do
    invocation_id = Keyword.get_lazy(opts, :invocation_id, &uuid/0)
    build_id = Keyword.get_lazy(opts, :build_id, &uuid/0)
    events = rewrite_invocation_id(events, invocation_id)

    run = %{
      hosts: hosts(opts),
      host_offset: Keyword.get(opts, :host_offset, 0),
      tls: Keyword.get(opts, :tls, false),
      retries: Keyword.get(opts, :retries, 0),
      ack_timeout: Keyword.get(opts, :ack_timeout_ms, @default_ack_timeout_ms),
      invocation_id: invocation_id,
      build_id: build_id,
      stream_id: %V1.StreamId{build_id: build_id, invocation_id: invocation_id, component: :TOOL},
      events: events,
      status: status(events),
      metadata: metadata(opts),
      project_id: Keyword.get(opts, :project_id, ""),
      delay: Keyword.get(opts, :delay_ms, 0),
      lifecycle?: Keyword.get(opts, :lifecycle, true),
      drop_after: Keyword.get(opts, :drop_after),
      duplicate_every: Keyword.get(opts, :duplicate_every),
      started_at: System.monotonic_time(:millisecond)
    }

    attempt(run, %{
      attempt: 0,
      from_seq: 1,
      acks: [],
      latencies: [],
      started?: false,
      dropped?: false
    })
  end

  defp hosts(opts) do
    case Keyword.get(opts, :hosts) do
      [_ | _] = hosts -> hosts
      _ -> [{Keyword.get(opts, :host, "localhost"), Keyword.get(opts, :port, 1985)}]
    end
  end

  # One connection attempt: dial, (re)start the stream from `st.from_seq`, finish the
  # build. A failed attempt keeps the acknowledgements it collected so the next one resumes
  # after them; the simulated drop reconnects without spending a retry.
  defp attempt(run, st) do
    {host, port} = Enum.at(run.hosts, rem(run.host_offset + st.attempt, length(run.hosts)))

    result =
      case GRPC.Stub.connect("#{host}:#{port}", connect_opts(host, run.tls)) do
        {:ok, channel} ->
          try do
            run_attempt(run, channel, st)
          catch
            # A stream the server closed early (e.g. UNAUTHENTICATED) makes later calls exit.
            :exit, reason -> {:error, {:stream_closed, reason}, st}
          after
            disconnect(channel)
          end

        {:error, reason} ->
          {:error, reason, st}
      end

    case result do
      {:ok, result} ->
        {:ok, Map.put(result, :attempts, st.attempt + 1)}

      {:error, :dropped, st} ->
        attempt(run, st)

      {:error, reason, st} when st.attempt < run.retries ->
        :telemetry.execute([:conveyor, :loadgen, :reconnect], %{attempt: st.attempt + 1}, %{
          invocation_id: run.invocation_id,
          reason: reason,
          from_seq: st.from_seq
        })

        Process.sleep(200 * (st.attempt + 1))
        attempt(run, %{st | attempt: st.attempt + 1})

      {:error, reason, _st} ->
        {:error, reason}
    end
  end

  # Closing a connection whose peer went away can time out inside the client (5 s call);
  # the build's outcome is already decided, so that must not take the caller down with it
  # (a load run died this way when the network dropped mid-run).
  defp disconnect(channel) do
    GRPC.Stub.disconnect(channel)
  catch
    :exit, _ -> :ok
  end

  defp run_attempt(run, channel, st) do
    conn = %{channel: channel, run: run}

    with {:ok, st} <- start_lifecycle(conn, st),
         {:ok, st} <- send_events(conn, st),
         {:ok, st} <- finish_lifecycle(conn, st) do
      {:ok,
       %{
         invocation_id: run.invocation_id,
         build_id: run.build_id,
         sent: length(run.events) + 1,
         acks: Enum.reverse(st.acks),
         latencies_ms: Enum.reverse(st.latencies),
         duration_ms: System.monotonic_time(:millisecond) - run.started_at
       }}
    end
  end

  defp start_lifecycle(_conn, %{started?: true} = st), do: {:ok, st}

  defp start_lifecycle(%{run: %{stream_id: stream_id}} = conn, st) do
    with :ok <-
           maybe_lifecycle(conn, [
             {%{stream_id | invocation_id: ""}, 1,
              {:build_enqueued, %V1.BuildEvent.BuildEnqueued{}}},
             {stream_id, 1,
              {:invocation_attempt_started,
               %V1.BuildEvent.InvocationAttemptStarted{attempt_number: 1}}}
           ]) do
      {:ok, %{st | started?: true}}
    else
      {:error, reason} -> {:error, reason, st}
    end
  end

  defp finish_lifecycle(%{run: %{stream_id: stream_id, status: status}} = conn, st) do
    with :ok <-
           maybe_lifecycle(conn, [
             {stream_id, 2,
              {:invocation_attempt_finished,
               %V1.BuildEvent.InvocationAttemptFinished{invocation_status: status}}},
             {%{stream_id | invocation_id: ""}, 2,
              {:build_finished, %V1.BuildEvent.BuildFinished{status: status}}}
           ]) do
      {:ok, st}
    else
      {:error, reason} -> {:error, reason, st}
    end
  end

  @doc "Wraps a BEP event as Bazel does on the wire."
  @spec ordered_event(V1.StreamId.t(), pos_integer(), BepEvent.t() | {atom(), struct()}) ::
          V1.OrderedBuildEvent.t()
  def ordered_event(stream_id, seq, %BepEvent{} = event) do
    any = %Google.Protobuf.Any{type_url: @bep_type_url, value: BepEvent.encode(event)}
    ordered_event(stream_id, seq, {:bazel_event, any})
  end

  # A pre-encoded event (see `pre_encode/1`): no protobuf work per replay.
  def ordered_event(stream_id, seq, {:encoded, bytes}) when is_binary(bytes) do
    any = %Google.Protobuf.Any{type_url: @bep_type_url, value: bytes}
    ordered_event(stream_id, seq, {:bazel_event, any})
  end

  def ordered_event(stream_id, seq, {kind, payload}) do
    %V1.OrderedBuildEvent{
      stream_id: stream_id,
      sequence_number: seq,
      event: %V1.BuildEvent{event_time: now(), event: {kind, payload}}
    }
  end

  # Sends events `st.from_seq..N` plus the stream-finished marker as N+1 on a new stream.
  # The first attempt of a `drop_after` run instead cancels the stream after that many
  # events without reading acks (a client that lost its connection cannot know what was
  # acked) and the next attempt resends everything from the first event, which exercises
  # the same deduplication path Bazel relies on after a retry. The old connection may still
  # hold frames queued for the cancelled stream (HTTP/2 flow control), so the resend always
  # dials a fresh one.
  defp send_events(%{run: %{drop_after: n}} = conn, %{dropped?: false} = st) when is_integer(n) do
    stream = Stub.publish_build_tool_event_stream(conn.channel, metadata: conn.run.metadata)

    # The connection may die before the deliberate drop (the server was killed): the
    # outcome is the same, a lost connection followed by a resend on a fresh one.
    try do
      conn.run.events
      |> Enum.with_index(1)
      |> Enum.take(n)
      |> Enum.each(fn {event, seq} -> send_one(conn, stream, seq, event) end)

      GRPC.Stub.cancel(stream)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    {:error, :dropped, %{st | dropped?: true, from_seq: 1}}
  end

  defp send_events(conn, st) do
    stream = Stub.publish_build_tool_event_stream(conn.channel, metadata: conn.run.metadata)
    parent = self()
    ref = make_ref()

    # Sending and receiving run in their own processes, as in Bazel, so client-observed
    # latency stays honest when events are paced and the wait for acks can be bounded. A
    # connection that dies mid-stream makes the adapter raise inside either; both end
    # quietly and the parent decides from the acks it saw.
    sender = spawn_link(fn -> send_loop(conn, stream, st.from_seq, parent, ref) end)
    receiver = spawn_link(fn -> receive_loop(stream, parent, ref) end)

    wait = %{timeout: conn.run.ack_timeout, last_seq: length(conn.run.events) + 1, ref: ref}
    result = await_acks(st, %{}, nil, wait)

    for pid <- [sender, receiver] do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    with {:error, {:stream_closed, :ack_timeout}, _} <- result, do: cancel(stream)
    flush(ref)
    result
  end

  defp send_loop(conn, stream, from_seq, parent, ref) do
    events = conn.run.events
    total = length(events)

    events
    |> Enum.with_index(1)
    |> Enum.drop(from_seq - 1)
    |> Enum.each(fn {event, seq} ->
      if conn.run.delay > 0, do: Process.sleep(conn.run.delay)
      send(parent, {ref, :sent, seq, System.monotonic_time(:microsecond)})
      send_one(conn, stream, seq, event)
    end)

    finished =
      {:component_stream_finished, %V1.BuildEvent.BuildComponentStreamFinished{type: :FINISHED}}

    final = request(conn.run.project_id, ordered_event(conn.run.stream_id, total + 1, finished))
    send(parent, {ref, :sent, total + 1, System.monotonic_time(:microsecond)})
    GRPC.Stub.send_request(stream, final, end_stream: true)
    send(parent, {ref, :sender_done})
  rescue
    _ -> send(parent, {ref, :sender_done})
  catch
    :exit, _ -> send(parent, {ref, :sender_done})
  end

  defp receive_loop(stream, parent, ref) do
    case GRPC.Stub.recv(stream) do
      {:ok, replies} ->
        Enum.reduce_while(replies, :ok, fn
          {:ok, %V1.PublishBuildToolEventStreamResponse{sequence_number: seq}}, :ok ->
            send(parent, {ref, :ack, seq, System.monotonic_time(:microsecond)})
            {:cont, :ok}

          {:error, reason}, :ok ->
            send(parent, {ref, :recv_error, reason})
            {:halt, :error}
        end)
        |> case do
          :ok -> send(parent, {ref, :recv_done})
          :error -> :ok
        end

      {:error, reason} ->
        send(parent, {ref, :recv_error, reason})
    end
  rescue
    e -> send(parent, {ref, :recv_error, e})
  catch
    :exit, reason -> send(parent, {ref, :recv_error, {:stream_closed, reason}})
  end

  # Collects acks (in order, with the client-observed latency of each first ack) until the
  # server ends the stream. The oldest unacknowledged event sets the deadline: once it has
  # waited `timeout` the connection is treated as gone, however many events the paced
  # sender keeps writing meanwhile (a stream whose acks stopped must not live on for as
  # long as the build). With nothing outstanding the wait is unbounded while the sender is
  # still pacing, and `timeout` from the moment it finished otherwise. Acks are contiguous,
  # so `from_seq` after the last one is where a resume starts.
  defp await_acks(st, pending, sender_done_at, %{ref: ref} = wait) do
    receive do
      {^ref, :sent, seq, t0} ->
        # The first send timestamp per sequence number wins (a duplicate resend must not
        # shorten the measured latency).
        await_acks(st, Map.put_new(pending, seq, t0), sender_done_at, wait)

      {^ref, :ack, seq, t} ->
        {latencies, pending} =
          case Map.pop(pending, seq) do
            {nil, pending} -> {st.latencies, pending}
            {t0, pending} -> {[(t - t0) / 1000 | st.latencies], pending}
          end

        st = %{
          st
          | acks: [seq | st.acks],
            latencies: latencies,
            from_seq: max(st.from_seq, seq + 1)
        }

        await_acks(st, pending, sender_done_at, wait)

      {^ref, :sender_done} ->
        await_acks(st, pending, System.monotonic_time(:microsecond), wait)

      {^ref, :recv_done} ->
        {:ok, st}

      {^ref, :recv_error, reason} ->
        {:error, reason, st}
    after
      remaining_ms(pending, sender_done_at, wait.timeout) ->
        # Every event acknowledged but the server never ended the stream: the build is
        # stored, and resending only the finish marker would make no sense.
        if pending == %{} and st.from_seq > wait.last_seq,
          do: {:ok, st},
          else: {:error, {:stream_closed, :ack_timeout}, st}
    end
  end

  defp remaining_ms(pending, sender_done_at, timeout) do
    since =
      cond do
        map_size(pending) > 0 -> pending |> Map.values() |> Enum.min()
        sender_done_at -> sender_done_at
        true -> nil
      end

    case since do
      nil -> :infinity
      t0 -> max(div(t0 - System.monotonic_time(:microsecond), 1000) + timeout, 0)
    end
  end

  defp cancel(stream) do
    GRPC.Stub.cancel(stream)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Drops messages the killed helpers may still have delivered for this attempt.
  defp flush(ref) do
    receive do
      {^ref, _} -> flush(ref)
      {^ref, _, _} -> flush(ref)
      {^ref, _, _, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  @doc false
  def connect_opts(_host, false), do: [adapter: GRPC.Client.Adapters.Mint]

  def connect_opts(host, true) do
    [
      adapter: GRPC.Client.Adapters.Mint,
      cred:
        GRPC.Credential.new(
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(host),
            depth: 3
          ]
        )
    ]
  end

  defp send_one(conn, stream, seq, event) do
    req = request(conn.run.project_id, ordered_event(conn.run.stream_id, seq, event))
    GRPC.Stub.send_request(stream, req)

    # Bazel resends an event it believes unacknowledged; the server must ack duplicates
    # without storing them twice.
    if conn.run.duplicate_every && rem(seq, conn.run.duplicate_every) == 0,
      do: GRPC.Stub.send_request(stream, req)

    :ok
  end

  defp request(project_id, obe),
    do: %V1.PublishBuildToolEventStreamRequest{ordered_build_event: obe, project_id: project_id}

  defp maybe_lifecycle(%{run: %{lifecycle?: false}}, _events), do: :ok

  defp maybe_lifecycle(conn, events) do
    Enum.reduce_while(events, :ok, fn {stream_id, seq, payload}, :ok ->
      req = %V1.PublishLifecycleEventRequest{
        build_event: ordered_event(stream_id, seq, payload),
        project_id: conn.run.project_id
      }

      case Stub.publish_lifecycle_event(conn.channel, req, metadata: conn.run.metadata) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:lifecycle, reason}}}
      end
    end)
  end

  defp status(events) do
    result =
      case Enum.find(events, &match?(%BepEvent{payload: {:finished, _}}, &1)) do
        %BepEvent{payload: {:finished, %{exit_code: %{code: 0}}}} -> :COMMAND_SUCCEEDED
        %BepEvent{payload: {:finished, _}} -> :COMMAND_FAILED
        nil -> :UNKNOWN_STATUS
      end

    %V1.BuildStatus{result: result}
  end

  defp metadata(opts) do
    case Keyword.get(opts, :api_key) do
      nil -> %{}
      key -> %{"x-api-key" => key}
    end
  end

  @doc """
  Encodes every event once so that replays cost no protobuf encoding. The Started and
  Finished events stay as structs: Started is rewritten with the replay's invocation id
  and Finished is inspected for the build status.
  """
  @spec pre_encode([BepEvent.t()]) :: [BepEvent.t() | {:encoded, binary()}]
  def pre_encode(events) do
    Enum.map(events, fn
      %BepEvent{payload: {:started, _}} = ev -> ev
      %BepEvent{payload: {:finished, _}} = ev -> ev
      %BepEvent{} = ev -> {:encoded, BepEvent.encode(ev)}
    end)
  end

  # Bazel puts the invocation id in the Started payload; keep the fixture consistent with
  # the stream id so each replay looks like a distinct build.
  defp rewrite_invocation_id(events, invocation_id) do
    Enum.map(events, fn
      %BepEvent{payload: {:started, started}} = ev ->
        %{ev | payload: {:started, %{started | uuid: invocation_id}}}

      ev ->
        ev
    end)
  end

  defp now do
    us = System.os_time(:microsecond)
    %Google.Protobuf.Timestamp{seconds: div(us, 1_000_000), nanos: rem(us, 1_000_000) * 1_000}
  end

  @doc false
  def uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
