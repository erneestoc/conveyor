defmodule Conveyor.Ingest.Verify do
  @moduledoc """
  Correctness oracle for replays and load tests: proves that an invocation was persisted
  exactly once and completely — final status, contiguous event segments covering 1..N with
  no gaps or overlaps, a matching decoded event count, and log offsets that chain.
  """
  import Ecto.Query

  alias Conveyor.Invocations
  alias Conveyor.Invocations.{EventSegment, Invocation, LogSegment}
  alias Conveyor.Repo

  @type problem :: tuple()

  @doc "Returns `:ok` or `{:error, problems}` for one invocation, given the number of BEP events sent."
  @spec check(String.t(), non_neg_integer()) :: :ok | {:error, [problem()]}
  def check(invocation_id, sent_events) do
    case Repo.get(Invocation, invocation_id) do
      nil ->
        {:error, [{:missing_invocation, invocation_id}]}

      inv ->
        segments =
          Repo.all(
            from s in EventSegment,
              where: s.invocation_id == ^inv.id,
              order_by: s.first_seq,
              select: {s.first_seq, s.last_seq, s.count}
          )

        logs =
          Repo.all(
            from s in LogSegment,
              where: s.invocation_id == ^inv.id,
              order_by: s.first_seq,
              select: {s.byte_offset, s.byte_size, s.line_offset, s.line_count}
          )

        segment_events = segments |> Enum.map(&elem(&1, 2)) |> Enum.sum()
        decoded = inv |> Invocations.raw_frames() |> length()

        problems =
          []
          |> check(not inv.stream_finished, {:stream_not_finished, inv.status})
          |> check(inv.status in ["in_progress", "disconnected"], {:not_final, inv.status})
          |> check(
            inv.last_event_seq != sent_events + 1,
            {:last_event_seq, inv.last_event_seq, sent_events + 1}
          )
          |> check(inv.event_count != sent_events, {:event_count, inv.event_count, sent_events})
          |> check(segment_events != sent_events, {:segment_events, segment_events, sent_events})
          |> check(not contiguous?(segments), {:segments_not_contiguous, segments})
          |> check(not log_chain?(logs), {:log_offsets_broken, logs})
          |> check(decoded != sent_events, {:decoded_events, decoded, sent_events})

        if problems == [], do: :ok, else: {:error, Enum.reverse(problems)}
    end
  end

  defp check(problems, true, problem), do: [problem | problems]
  defp check(problems, false, _problem), do: problems

  defp contiguous?(segments) do
    segments
    |> Enum.reduce_while(1, fn {first, last, count}, expected ->
      if first == expected and last >= first and count == last - first + 1,
        do: {:cont, last + 1},
        else: {:halt, :broken}
    end)
    |> then(&(&1 != :broken))
  end

  defp log_chain?(logs) do
    logs
    |> Enum.reduce_while({0, 0}, fn {byte_offset, byte_size, line_offset, line_count},
                                    {bytes, lines} ->
      if byte_offset == bytes and line_offset == lines,
        do: {:cont, {bytes + byte_size, lines + line_count}},
        else: {:halt, :broken}
    end)
    |> then(&(&1 != :broken))
  end
end
