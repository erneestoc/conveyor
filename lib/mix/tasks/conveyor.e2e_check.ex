defmodule Mix.Tasks.Conveyor.E2eCheck do
  @shortdoc "Verifies that a real Bazel build streamed into this database landed intact"
  @moduledoc """
  Used by the Bazel end-to-end workflow after `bazel test ... --bes_backend`: finds the
  newest invocation tagged `bazel=<version>`, waits for it to finish, and checks it with
  the persistence oracle plus a few expectations about what the fixture workspace build
  must have produced. Exits non-zero on any mismatch.

      mix conveyor.e2e_check --bazel 9.2.0 [--timeout-s 60]
  """
  use Mix.Task

  import Ecto.Query

  alias Conveyor.Invocations
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Repo

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [bazel: :string, timeout_s: :integer])
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    case Repo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    version = opts[:bazel] || raise "--bazel VERSION is required"
    deadline = System.monotonic_time(:millisecond) + (opts[:timeout_s] || 60) * 1000

    case check(version, deadline) do
      :ok -> Mix.shell().info("e2e ok: Bazel #{version} build verified")
      {:error, reason} -> Mix.raise("e2e check failed: #{reason}")
    end
  end

  @doc false
  def check(version, deadline) do
    case latest(version) do
      nil ->
        wait_or(deadline, "no invocation tagged bazel=#{version}", fn ->
          check(version, deadline)
        end)

      %Invocation{status: "in_progress"} ->
        wait_or(deadline, "invocation still in progress", fn -> check(version, deadline) end)

      inv ->
        verify(inv)
    end
  end

  defp latest(version) do
    Repo.one(
      from i in Invocation,
        where: fragment("? ->> 'bazel' = ?", i.tags, ^version),
        order_by: [desc: i.inserted_at],
        limit: 1
    )
  end

  defp wait_or(deadline, reason, retry) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1000)
      retry.()
    else
      {:error, reason}
    end
  end

  defp verify(inv) do
    with :ok <- Conveyor.Ingest.Verify.check(inv.id, inv.event_count),
         :ok <- expect(inv.status == "succeeded", "status is #{inv.status}"),
         :ok <- expect(inv.exit_code_name == "SUCCESS", "exit is #{inspect(inv.exit_code_name)}"),
         :ok <-
           expect(inv.targets_configured >= 2, "#{inv.targets_configured} targets configured"),
         :ok <- expect(inv.tests_passed >= 1, "#{inv.tests_passed} tests passed"),
         :ok <- expect(inv.bazel_version != nil, "no bazel version recorded"),
         :ok <-
           expect(
             Invocations.log(inv) =~ "Build completed successfully",
             "log lacks completion line"
           ),
         :ok <- expect(length(Invocations.targets(inv)) >= 2, "target rows missing") do
      :ok
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp expect(true, _), do: :ok
  defp expect(false, reason), do: {:error, reason}
end
