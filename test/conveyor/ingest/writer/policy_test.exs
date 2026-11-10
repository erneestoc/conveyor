defmodule Conveyor.Ingest.Writer.PolicyTest do
  use ExUnit.Case, async: true

  alias Conveyor.Ingest.Writer.Policy

  # A unit is named by its invocation and its position among that invocation's units.
  defp k(name), do: {name, 0}

  # Runs a group against a script of attempt outcomes; returns the attempts the policy
  # asked for (`{keys, delay waited before}`) and the verdicts. An outcome may be a function of the keys
  # attempted.
  defp run(keys, script, opts \\ [retry_delays: [50, 200, 800]]) do
    drive(Policy.new(keys, opts), script, 0, [])
  end

  defp drive(policy, script, delay, attempts) do
    case Policy.next(policy) do
      {:done, verdicts} ->
        assert script == [] or match?([:rest | _], script), "unused outcomes: #{inspect(script)}"
        {Enum.reverse(attempts), verdicts}

      {:attempt, keys, policy} ->
        {outcome, script} =
          case script do
            [:rest, f] -> {f, [:rest, f]}
            [o | rest] -> {o, rest}
          end

        outcome = if is_function(outcome), do: outcome.(keys), else: outcome
        {policy, next_delay} = Policy.record(policy, outcome)
        drive(policy, script, next_delay, [{keys, delay} | attempts])
    end
  end

  @a {"a", 0}
  @b {"b", 0}
  @c {"c", 0}
  @d {"d", 0}
  @unavailable {:error, :unavailable, "no connection"}
  @deadlock {:error, :contention, "deadlock"}
  @refused {:error, :data, "value too long"}

  describe "one group, by the outcome of its attempts" do
    for {name, keys, script, attempts, verdicts} <- [
          {"committed at once", [@a, @b], [:committed], [{[@a, @b], 0}],
           %{@a => :committed, @b => :committed}},
          {"an empty group has nothing to do", [], [], [], %{}},
          {"a fenced unit leaves; the rest commits in one more attempt", [@a, @b, @c],
           [{:fenced, [@b]}, :committed], [{[@a, @b, @c], 0}, {[@a, @c], 0}],
           %{@a => :committed, @b => :fenced, @c => :committed}},
          {"a fenced unit takes the later units of its invocation with it",
           [{"a", 0}, @b, {"a", 1}, {"a", 2}], [{:fenced, [{"a", 1}]}, :committed],
           [{[{"a", 0}, @b, {"a", 1}, {"a", 2}], 0}, {[{"a", 0}, @b], 0}],
           %{{"a", 0} => :committed, @b => :committed, {"a", 1} => :fenced, {"a", 2} => :fenced}},
          {"everything fenced: no second attempt", [@a], [{:fenced, [@a]}], [{[@a], 0}],
           %{@a => :fenced}},
          {"unavailable: the same units after each delay, then committed", [@a, @b],
           [@unavailable, @unavailable, :committed],
           [{[@a, @b], 0}, {[@a, @b], 50}, {[@a, @b], 200}],
           %{@a => :committed, @b => :committed}},
          {"unavailable past the last delay: the whole group fails, nothing is split",
           [@a, @b, @c], [@unavailable, @unavailable, @unavailable, @unavailable],
           [{[@a, @b, @c], 0}, {[@a, @b, @c], 50}, {[@a, @b, @c], 200}, {[@a, @b, @c], 800}],
           %{
             @a => {:failed, "no connection"},
             @b => {:failed, "no connection"},
             @c => {:failed, "no connection"}
           }},
          {"a refused row is not retried: the group is halved until the unit is alone",
           [@a, @b, @c, @d], [@refused, :committed, @refused, @refused, :committed],
           [{[@a, @b, @c, @d], 0}, {[@a, @b], 0}, {[@c, @d], 0}, {[@c], 0}, {[@d], 0}],
           %{
             @a => :committed,
             @b => :committed,
             @c => {:failed, "value too long"},
             @d => :committed
           }},
          {"a unit that fails takes the later units of its invocation with it",
           [{"a", 0}, {"a", 1}], [@refused, @refused],
           [{[{"a", 0}, {"a", 1}], 0}, {[{"a", 0}], 0}],
           %{{"a", 0} => {:failed, "value too long"}, {"a", 1} => {:failed, "value too long"}}},
          {"contention is retried, then halved", [@a, @b],
           [@deadlock, @deadlock, @deadlock, @deadlock, :committed, :committed],
           [
             {[@a, @b], 0},
             {[@a, @b], 50},
             {[@a, @b], 200},
             {[@a, @b], 800},
             {[@a], 0},
             {[@b], 0}
           ], %{@a => :committed, @b => :committed}},
          {"the delays are the group's, not each attempt's", [@a, @b],
           [@unavailable, @refused, @unavailable, @unavailable, @unavailable],
           [{[@a, @b], 0}, {[@a, @b], 50}, {[@a], 0}, {[@a], 200}, {[@a], 800}],
           %{@a => {:failed, "no connection"}, @b => {:failed, "no connection"}}},
          {"a fence found while halving still evicts", [@a, @b, @c, @d],
           [@refused, {:fenced, [@a]}, :committed, :committed],
           [{[@a, @b, @c, @d], 0}, {[@a, @b], 0}, {[@b], 0}, {[@c, @d], 0}],
           %{@a => :fenced, @b => :committed, @c => :committed, @d => :committed}}
        ] do
      test name do
        assert {unquote(Macro.escape(attempts)), unquote(Macro.escape(verdicts))} ==
                 run(unquote(Macro.escape(keys)), unquote(Macro.escape(script)))
      end
    end
  end

  describe "the bound" do
    test "one refused unit among 256 is isolated in about 2·log2(n) attempts" do
      keys = for i <- 1..256, do: k("inv-#{i}")
      poison = k("inv-77")

      outcome = fn attempted ->
        if poison in attempted, do: {:error, :data, "refused"}, else: :committed
      end

      {attempts, verdicts} = run(keys, [:rest, outcome])
      assert length(attempts) == 17
      assert verdicts[poison] == {:failed, "refused"}
      assert Enum.count(verdicts, fn {_, v} -> v == :committed end) == 255
    end

    test "a group that is refused whatever its size stops at the budget, every unit settled" do
      keys = for i <- 1..256, do: k("inv-#{i}")
      {attempts, verdicts} = run(keys, [:rest, {:error, :data, "refused"}])
      assert length(attempts) == Policy.max_attempts(256, 3)
      assert Policy.max_attempts(256, 3) == 21
      assert map_size(verdicts) == 256
      assert Enum.all?(verdicts, fn {_, v} -> v == {:failed, "refused"} end)
    end

    test "a fence that never names an attempted unit cannot loop" do
      {attempts, verdicts} = run([@a, @b], [:rest, {:fenced, [@c]}])
      assert length(attempts) == Policy.max_attempts(2, 3)

      assert verdicts == %{
               @a => {:failed, :attempts_exhausted},
               @b => {:failed, :attempts_exhausted}
             }
    end

    test "a single unit is attempted at most once per delay, plus one" do
      {attempts, verdicts} = run([@a], [:rest, {:error, :contention, "deadlock"}])
      assert Enum.map(attempts, &elem(&1, 1)) == [0, 50, 200, 800]
      assert verdicts == %{@a => {:failed, "deadlock"}}
    end
  end

  describe "evict/3" do
    test "takes units out before an attempt (a deadline) with their followers" do
      policy = Policy.new([{"a", 0}, @b, {"a", 1}])
      assert Policy.open(policy) == [{"a", 0}, @b, {"a", 1}]
      policy = Policy.evict(policy, [{"a", 0}], :expired)
      assert {:attempt, [@b], policy} = Policy.next(policy)

      assert {:done, %{{"a", 0} => :expired, {"a", 1} => :expired, @b => :committed}} ==
               policy |> Policy.record(:committed) |> elem(0) |> Policy.next()
    end

    test "a group emptied by eviction is done" do
      assert {:done, %{@a => :expired}} ==
               [@a] |> Policy.new() |> Policy.evict([@a], :expired) |> Policy.next()
    end
  end
end
