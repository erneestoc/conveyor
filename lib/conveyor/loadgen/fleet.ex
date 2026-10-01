defmodule Conveyor.Loadgen.Fleet do
  @moduledoc """
  Entry point for load generators running as containers (`bin/conveyor eval
  "Conveyor.Loadgen.Fleet.main()"`): the fleet test runs the Conveyor image itself as
  Fargate tasks with a corpus of real builds under `/corpus` (deploy/trial/loadgen.tf).
  The target, key and profile come from the environment so one task definition serves
  every run: `LOADGEN_HOSTS` (`host:1985,...`), `LOADGEN_API_KEY`, `LOADGEN_ARGS` (any
  `Conveyor.Loadgen.CLI` switches, e.g. `--tls --streams 250 --duration-s 600 --delay-ms 500`),
  `LOADGEN_FIXTURES` (default `/corpus/*.bep`).
  """

  @doc "Runs the generator with the arguments `args/1` derives and exits with its status."
  @spec main() :: no_return()
  def main do
    {:ok, _} = Application.ensure_all_started(:grpc)
    Conveyor.Loadgen.CLI.main(args(System.get_env()))
  end

  @doc "The CLI arguments for an environment map."
  @spec args(%{String.t() => String.t()}) :: [String.t()]
  def args(env) do
    extra = env |> Map.get("LOADGEN_ARGS", "") |> String.split(~r/\s+/, trim: true)

    [
      "--hosts",
      Map.fetch!(env, "LOADGEN_HOSTS"),
      "--api-key",
      Map.get(env, "LOADGEN_API_KEY", ""),
      "--fixtures",
      Map.get(env, "LOADGEN_FIXTURES", "/corpus/*.bep")
    ] ++ extra
  end
end
