defmodule Mix.Tasks.Conveyor.Loadgen do
  @shortdoc "Runs the BES load generator against a Conveyor server"
  @moduledoc """
  Runs the load generator (see `Conveyor.Loadgen.CLI` for the options):

      mix conveyor.loadgen --hosts localhost:1985 --api-key KEY --streams 200 --builds 2000

  `--verify` starts the repo configured for this Mix env and runs the persistence oracle
  on every generated invocation.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    if "--verify" in args do
      {:ok, _} = Application.ensure_all_started(:postgrex)
      {:ok, _} = Application.ensure_all_started(:ecto_sql)

      case Conveyor.Repo.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    Conveyor.Loadgen.CLI.main(args)
  end
end
