defmodule Conveyor.Ingest.Verify do
  @moduledoc """
  Correctness oracle for replays and load tests: proves that an invocation was persisted
  exactly once and completely — final status, the sequence and event count on the row, and
  the raw bytes read back from wherever they live (`Conveyor.RawStore.audit/1`): as many
  events as were sent, decoded and indexed, the whole log, stored without gaps or overlaps.
  A frame the build skipped on purpose (a successful per-action event, PLAN §28.1) is not
  in the store; it is counted on the row and by the segment that follows it, so "sent"
  must equal "stored plus skipped" and every sequence number is one or the other.
  One oracle for every form the bytes take: segments, byte ranges or archived blobs.
  """
  alias Conveyor.Invocations.Invocation
  alias Conveyor.{RawStore, Repo}

  @type problem :: tuple()

  @doc "Returns `:ok` or `{:error, problems}` for one invocation, given the number of BEP events sent."
  @spec check(String.t(), non_neg_integer()) :: :ok | {:error, [problem()]}
  def check(invocation_id, sent_events) do
    case Repo.get(Invocation, invocation_id) do
      nil ->
        {:error, [{:missing_invocation, invocation_id}]}

      inv ->
        check_invocation(inv, sent_events)
    end
  end

  defp check_invocation(inv, sent_events) do
    stored = RawStore.audit(inv)
    kept = sent_events - inv.events_skipped

    problems =
      []
      |> check(not inv.stream_finished, {:stream_not_finished, inv.status})
      |> check(inv.status in ["in_progress", "disconnected"], {:not_final, inv.status})
      |> check(
        inv.last_event_seq != sent_events + 1,
        {:last_event_seq, inv.last_event_seq, sent_events + 1}
      )
      |> check(inv.event_count != sent_events, {:event_count, inv.event_count, sent_events})
      # Every event sent is either a frame in the store or one of the frames the build
      # skipped on purpose (successful per-action events, PLAN §28.1): the row counts
      # those, and the store's own account of them (per segment) must agree with it.
      |> check(inv.events_skipped > sent_events, {:events_skipped, inv.events_skipped})
      |> check(
        stored.skipped > inv.events_skipped,
        {:skipped_frames, stored.skipped, inv.events_skipped}
      )
      |> check(stored.events != kept, {:segment_events, stored.events, kept})
      |> then(&(Enum.reverse(stored.problems) ++ &1))
      |> check(stored.log_bytes != inv.log_bytes, {:log_bytes, stored.log_bytes, inv.log_bytes})
      |> check(stored.frames != kept, {:decoded_events, stored.frames, kept})

    if problems == [], do: :ok, else: {:error, Enum.reverse(problems)}
  end

  defp check(problems, true, problem), do: [problem | problems]
  defp check(problems, false, _problem), do: problems
end
