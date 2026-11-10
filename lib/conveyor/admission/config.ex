defmodule Conveyor.Admission.Config do
  @moduledoc """
  The knobs of admission (`Conveyor.Admission`), read once when the sampler starts
  (`from_env/0`: `config :conveyor, Conveyor.Admission` plus the writer's hold and deadline).

  The thresholds are fractions of the writer's deadline, so they move with it. With the
  default 20 s deadline: elevated at 3 s (back at 1 s), shedding at 5 s (back at 2 s; every
  new build refused from 10 s), critical at 15 s (back at 10 s). `PLAN.md` §26.4 has the reasoning.
  """

  defstruct enabled: true,
            sample_ms: 250,
            # The writer's deadline and hold (`Writer.Config`): pressure is the age of the
            # oldest waiting batch beyond the hold, as a fraction of the deadline.
            deadline_ms: 20_000,
            hold_ms: 2,
            # The pool's queue target: a mean wait of twice this counts as a full deadline.
            queue_target_ms: 1_000,
            # Backlog bytes that count as a full deadline (memory, not time).
            max_backlog_bytes: 512 * 1024 * 1024,
            # {elevated, shedding, critical}
            enter: {0.15, 0.25, 0.75},
            exit: {0.05, 0.10, 0.50},
            # Where every new build is refused; from the shedding threshold up to here the
            # refused share grows linearly.
            shed_all: 0.50,
            # How fast refused builds are taken back once the pressure allows: points of the
            # refused share per second (2: from all to none in 50 s).
            readmit_per_s: 2.0,
            # Samples the pressure is the maximum of (the gauge reads 0 between a flush and
            # the next batch).
            window: 4,
            # Readiness: how long the node must be shedding before it may leave the
            # balancer, and how long it then stays out at least.
            unready_after_ms: 10_000,
            unready_min_ms: 30_000,
            # A peer's report older than this is not counted.
            peer_ttl_ms: 2_000,
            # Database probe: interval (0: off) and failures in a row that count as "gone".
            probe_ms: 2_000,
            probe_failures: 3

  @type t :: %__MODULE__{}

  @doc "The node's configuration."
  @spec from_env() :: t()
  def from_env do
    env = Application.get_env(:conveyor, Conveyor.Admission, [])
    writer = Conveyor.Ingest.Writer.Config.from_env()
    repo = Application.get_env(:conveyor, Conveyor.Repo, [])

    %__MODULE__{}
    |> struct(
      deadline_ms: writer.deadline_ms,
      hold_ms: writer.hold_ms,
      queue_target_ms: Keyword.get(repo, :queue_target, 50)
    )
    |> struct(Keyword.take(env, Map.keys(%__MODULE__{}) -- [:__struct__]))
  end
end
