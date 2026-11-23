defmodule Conveyor.Seed.RbeDemo do
  @moduledoc """
  Demo data for the Duplicate work pages (`mix conveyor.seed --rbe-demo`), uploaded
  through the HTTP API of a running server so the real pipeline runs: every build is a
  recorded event stream (`PUT /api/v1/invocations/:id/bep`) with its start moved to the
  last day and a half, followed by an execution log written by `Conveyor.ExecLog.Synth`
  (`PUT …/artifacts/execution.log.zst`), parsed by the server's `parse` queue.

  What it makes (all slugs start with `rbe-demo-`; a second run replaces the first):

    * **`rbe-demo-ios`**: four pipelines of three shards that start together against one
      cache. Shards race on the shared modules (racing duplicates, a few within the
      clock tolerance), later pipelines hit the cache for what did not change, a nightly
      build without the cache repeats everything (sequential, within the project).
      `SwiftCompile` states `cores` in an exec property, the other mnemonics fall back;
      one shard builds a module with an extra input (a near miss, same commit), a genrule
      writes different outputs under one key (not deterministic), and there are a
      `no-remote` signing step, a test that may not be cached and a failed compile.
      No action digests: the fallback key.
    * **`rbe-demo-go-api`, `-go-worker`, `-go-web`** in the cache group `rbe-demo-monorepo`:
      a cache per machine, with action digests. Every app compiles the shared libraries
      again: the worker after the api has finished (sequential, across projects), the web
      app while the worker is still at it (racing, across projects). A second build on a
      warm host hits its own cache; a rebuild on a fresh host repeats the app's own
      packages (sequential, within the project).
    * **`rbe-demo-empty`**: builds without any execution log (the zero-coverage state).
  """
  import Ecto.Query

  alias Conveyor.Bep.Fixture
  alias Conveyor.ExecLog.{ActionKey, Synth}
  alias Conveyor.Invocations.Invocation
  alias Conveyor.{Projects, Repo}
  alias Conveyor.Rbe.{Groups, Settings}

  @fixture "test/fixtures/bep/clean_build_and_test.bep"
  @group "rbe-demo-monorepo"
  @jobs 6
  @key_name "rbe demo seed"

  @ios_modules ~w(Networking Persistence DesignSystem Analytics FeatureFlags Authentication
                  CheckoutFlow ProductCatalog SearchIndex PushNotifications ImagePipeline Localization)
  @go_libs ~w(auth config db grpcutil httpx logging metrics queue retry storage tracing validate)

  @type build :: %{
          project: String.t(),
          id: String.t(),
          start: DateTime.t(),
          host: String.t(),
          tags: %{String.t() => String.t()},
          spawns: [Synth.spawn()] | nil
        }

  @doc """
  Seeds the demo. Options: `:url` (the running server, default `http://localhost:4100`),
  `:now`, and for tests `:put` (`fn path, api_key, body -> status`) and `:await`
  (`fn invocation_ids -> :ok`, called after the uploads). Returns the builds per project
  slug.
  """
  @spec run(keyword()) :: %{String.t() => non_neg_integer()}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    url = Keyword.get(opts, :url, "http://localhost:4100")
    put = Keyword.get(opts, :put, &http_put(url, &1, &2, &3))
    await = Keyword.get(opts, :await, &await_parsed/1)
    nonce = Integer.to_string(DateTime.to_unix(now))

    keys = Map.new(projects(), fn {slug, name} -> {slug, reset!(slug, name)} end)
    events = Fixture.read!(Path.join(File.cwd!(), @fixture))
    builds = builds(now, nonce)

    for b <- builds do
      key = Map.fetch!(keys, b.project)
      202 = put.("/api/v1/invocations/#{b.id}/bep", key, bep(events, b))
    end

    with_log = Enum.filter(builds, & &1.spawns)

    for b <- with_log do
      body = Synth.encode(b.id, b.spawns)

      201 =
        upload_log(
          put,
          "/api/v1/invocations/#{b.id}/artifacts/execution.log.zst",
          b,
          keys,
          body,
          50
        )
    end

    await.(Enum.map(with_log, & &1.id))
    Enum.frequencies_by(builds, & &1.project)
  end

  defp projects do
    [
      {"rbe-demo-ios", "Demo iOS (shards, one cache)"},
      {"rbe-demo-go-api", "Demo Go api"},
      {"rbe-demo-go-worker", "Demo Go worker"},
      {"rbe-demo-go-web", "Demo Go web"},
      {"rbe-demo-empty", "Demo without logs"}
    ]
  end

  # The project as a fresh one: earlier demo builds, their hours, keys and hosts go, the
  # settings are the demo's, and a new upload key replaces the last run's.
  defp reset!(slug, name) do
    project =
      case Projects.get_project_by_slug(slug) do
        nil ->
          {:ok, project} = Projects.create_project(%{slug: slug, name: name})
          project

        project ->
          project
      end

    future = DateTime.add(DateTime.utc_now(), 365, :day)
    Conveyor.Workers.BuildRetention.delete_before(project, future, 0)
    Conveyor.Metrics.Rollup.prune!(project.id, future)
    Conveyor.Rbe.Fleet.prune!(project.id, future)
    Repo.delete_all(from k in ActionKey, where: k.scope == ^project.id)

    Repo.delete_all(
      from k in Projects.ApiKey, where: k.project_id == ^project.id and k.name == ^@key_name
    )

    {:ok, project} =
      if String.contains?(slug, "-go-"), do: Groups.put(project, @group), else: {:ok, project}

    if group = Groups.of(project),
      do: Repo.delete_all(from k in ActionKey, where: k.scope == ^Groups.scope(group))

    {:ok, _project} =
      Settings.put(project, %{
        "cores" => "",
        "pipeline_key" => "pipeline",
        "tolerance_s" => "2",
        "cores_properties" => "",
        "cores_unit" => "auto"
      })

    {:ok, _key, plaintext} =
      Projects.create_api_key(project, %{name: @key_name, scopes: ["upload"]})

    plaintext
  end

  # --- the scenario ----------------------------------------------------------------------------

  @doc false
  @spec builds(DateTime.t(), String.t()) :: [build()]
  def builds(now, nonce) do
    at = fn minutes -> DateTime.add(now, -minutes * 60, :second) end
    ios(at, nonce) ++ go(at, nonce) ++ empty(at)
  end

  defp ios(at, nonce) do
    pipelines = [{1620, "a1f3c9e"}, {1260, "7be02d4"}, {360, "c44d1a8"}, {180, "e90b7f2"}]

    shards =
      for {{minutes, commit}, p} <- Enum.with_index(pipelines, 1), shard <- 1..3 do
        start = DateTime.add(at.(minutes), Enum.at([0, 2, 5], shard - 1), :second)

        spawns =
          ios_shared(nonce, p, shard)
          |> Kernel.++(ios_own(nonce, p, shard))
          |> schedule(start)

        build("rbe-demo-ios", start, "ios-shard-#{shard}", spawns, %{
          "pipeline" => "ios-#{1000 + p}",
          "commit" => commit,
          "branch" => "main",
          "ci" => "true"
        })
      end

    # The nightly build ignores the cache: everything it runs had been finished before.
    nightly_start = at.(900)

    nightly =
      build(
        "rbe-demo-ios",
        nightly_start,
        "ios-nightly-1",
        nonce |> ios_shared(2, 1) |> Enum.map(&Map.delete(&1, :hit)) |> schedule(nightly_start),
        %{"pipeline" => "ios-nightly", "commit" => "7be02d4", "branch" => "main", "ci" => "true"}
      )

    shards ++ [nightly]
  end

  # What every shard of a pipeline builds. A module's sources change with some pipelines
  # (a new key); what did not change since an earlier pipeline is a cache hit.
  defp ios_shared(nonce, pipeline, shard) do
    modules =
      for {module, i} <- Enum.with_index(@ios_modules) do
        version = if rem(i, 3) == 0, do: 1, else: pipeline
        changed? = version == pipeline
        target = "//ios/Modules/#{module}/Sources/#{module}Kit:#{module}Kit_swift_library"

        swift =
          action(nonce, "SwiftCompile", target, "#{module}.swiftmodule", 9_000 + i * 2_300,
            version: version,
            platform: %{"cores" => "4", "OSFamily" => "macos"},
            # Pipeline 3, shard 2: the stamp file leaked into the inputs of one module.
            extra: if(pipeline == 3 and shard == 2 and module == "Persistence", do: "stamp")
          )

        objc =
          action(nonce, "ObjcCompile", target, "#{module}_bridge.o", 2_500 + i * 700,
            version: version
          )

        Enum.map([swift, objc], &if(changed?, do: &1, else: Map.put(&1, :hit, true)))
      end

    info =
      action(nonce, "Genrule", "//ios/tools:build_info", "build_info.plist", 1_400,
        version: pipeline,
        output_version: shard
      )

    sign =
      action(nonce, "ProcessAndSign", "//ios/App:App", "App.ipa", 21_000,
        version: pipeline,
        remotable: false
      )

    List.flatten(modules) ++ [info, sign]
  end

  # What only this shard runs: its tests (one may not be cached), and once a failure.
  defp ios_own(nonce, pipeline, shard) do
    tests =
      for n <- 1..4 do
        action(
          nonce,
          "TestRunner",
          "//ios/Tests/Shard#{shard}:UnitTests_#{n}",
          "test_#{shard}_#{n}.log",
          14_000 + n * 3_000,
          version: pipeline
        )
      end

    ui =
      action(nonce, "TestRunner", "//ios/Tests/UI:Snapshot_#{shard}", "ui_#{shard}.log", 38_000,
        version: pipeline,
        cacheable: false
      )

    failed =
      if pipeline == 2 and shard == 3 do
        [
          action(
            nonce,
            "SwiftCompile",
            "//ios/Experimental:Widgets",
            "Widgets.swiftmodule",
            6_000,
            version: pipeline,
            exit_code: 1
          )
        ]
      else
        []
      end

    tests ++ [ui] ++ failed
  end

  defp go(at, nonce) do
    rounds = [{1500, "5d2e81b", 1}, {420, "0c9af37", 2}]
    apps = [{"api", 0}, {"worker", 11}, {"web", 11}]

    first =
      for {minutes, commit, round} <- rounds, {app, later} <- apps do
        # The web app starts two seconds after the worker: both compile the shared
        # libraries the api finished minutes ago, and web's start falls inside worker's run.
        skew = if app == "web", do: 2, else: 0
        start = DateTime.add(at.(minutes - later), skew, :second)
        # Only the worker and the web app use the job libraries: nobody has finished them
        # when the two compile them at the same time (racing, across projects).
        jobs = if app == "api", do: [], else: go_jobs(nonce, round)

        spawns =
          (go_libs(nonce, round) ++ jobs ++ go_app(nonce, app, round)) |> schedule(start)

        go_build(app, start, "go-#{app}-r#{round}-fresh", spawns, commit)
      end

    # The api again on its warm host (its own cache hits), then on a fresh one.
    {minutes, commit, round} = List.last(rounds)
    warm_start = at.(minutes - 40)

    warm =
      (go_libs(nonce, round) ++ go_app(nonce, "api", round))
      |> Enum.map(&Map.put(&1, :hit, true))
      |> schedule(warm_start)

    cold_start = at.(minutes - 70)
    cold = (go_libs(nonce, round) ++ go_app(nonce, "api", round)) |> schedule(cold_start)

    first ++
      [
        go_build("api", warm_start, "go-api-r#{round}-fresh", warm, commit),
        go_build("api", cold_start, "go-api-r#{round}-scaled", cold, commit)
      ]
  end

  defp go_build(app, start, host, spawns, commit),
    do:
      build("rbe-demo-go-#{app}", start, host, spawns, %{
        "pipeline" => "go-#{app}",
        "commit" => commit,
        "branch" => "main",
        "ci" => "true"
      })

  defp go_libs(nonce, round) do
    stdlib =
      action(nonce, "GoStdlib", "@io_bazel_rules_go//:stdlib", "stdlib.a", 52_000, digest: true)

    libs =
      for {lib, i} <- Enum.with_index(@go_libs) do
        action(nonce, "GoCompilePkg", "//go/lib/#{lib}:#{lib}", "#{lib}.a", 3_000 + i * 900,
          version: if(rem(i, 4) == 0, do: round, else: 1),
          digest: true,
          platform: if(rem(i, 2) == 0, do: %{"cpu" => "2"})
        )
      end

    [stdlib | libs]
  end

  defp go_jobs(nonce, round) do
    for lib <- ~w(scheduler cron leases) do
      action(nonce, "GoCompilePkg", "//go/lib/jobs/#{lib}:#{lib}", "jobs_#{lib}.a", 7_500,
        version: round,
        digest: true
      )
    end
  end

  defp go_app(nonce, app, round) do
    packages =
      for pkg <- ~w(cmd handlers internal/service internal/store) do
        action(
          nonce,
          "GoCompilePkg",
          "//go/apps/#{app}/#{pkg}:#{Path.basename(pkg)}",
          "#{app}_#{Path.basename(pkg)}.a",
          4_200,
          version: round,
          digest: true
        )
      end

    link =
      action(nonce, "GoLink", "//go/apps/#{app}/cmd:#{app}", "#{app}_bin", 8_500,
        version: round,
        digest: true
      )

    test =
      action(
        nonce,
        "TestRunner",
        "//go/apps/#{app}/internal/service:service_test",
        "#{app}_test.log",
        17_000,
        version: round,
        digest: true
      )

    packages ++ [link, test]
  end

  defp empty(at) do
    for minutes <- [1400, 800, 200],
        do: build("rbe-demo-empty", at.(minutes), "ci-runner-1", nil, %{"branch" => "main"})
  end

  defp build(project, start, host, spawns, tags),
    do: %{
      project: project,
      id: Ecto.UUID.generate(),
      start: start,
      host: host,
      tags: tags,
      spawns: spawns
    }

  # An action of the demo: its identity is the nonce of the run, the mnemonic, the target
  # and a version; `:extra` adds an input (another key for the same output), and
  # `:output_version` changes what it wrote (the same key).
  defp action(nonce, mnemonic, target, output, ms, opts) do
    version = Keyword.get(opts, :version, 1)
    identity = Enum.join([nonce, mnemonic, target, version], "|")
    package = target |> String.trim_leading("/") |> String.split(":") |> hd()

    inputs =
      for n <- 1..6 do
        {"#{package}/src_#{n}", Synth.hash([identity, "in", Integer.to_string(n)])}
      end ++
        if(opts[:extra],
          do: [{"bazel-out/volatile-status.txt", Synth.hash([identity, opts[:extra]])}],
          else: []
        )

    %{
      mnemonic: mnemonic,
      target: target,
      args: [
        "tools/#{String.downcase(mnemonic)}",
        "-o",
        "bazel-out/bin/#{package}/#{output}",
        "--rev=#{version}"
      ],
      inputs: inputs,
      output:
        {"bazel-out/bin/#{package}/#{output}",
         Synth.hash([identity, "out", to_string(Keyword.get(opts, :output_version, 1))])},
      ms: ms,
      platform: opts[:platform],
      digest: if(opts[:digest], do: Synth.hash(["digest", identity])),
      exit_code: Keyword.get(opts, :exit_code, 0),
      remotable: Keyword.get(opts, :remotable, true),
      cacheable: Keyword.get(opts, :cacheable, true)
    }
  end

  # Starts the spawns the way `--jobs` would: each on the lane that is free first.
  defp schedule(spawns, start) do
    {spawns, _lanes} =
      Enum.map_reduce(spawns, List.duplicate(0, @jobs), fn spawn, lanes ->
        offset = Enum.min(lanes)
        ms = if spawn[:hit], do: 0, else: spawn.ms
        lanes = List.replace_at(lanes, Enum.find_index(lanes, &(&1 == offset)), offset + ms)
        {Map.put(spawn, :start, DateTime.add(start, offset, :millisecond)), lanes}
      end)

    spawns
  end

  # --- the event stream of a build -------------------------------------------------------------

  # The recorded stream as this build: its id, host, start, tags and a length that matches
  # its execution log.
  @doc false
  @spec bep([struct()], build()) :: binary()
  def bep(events, build) do
    action_ms = for(s <- build.spawns || [], !s[:hit], do: s.ms) |> Enum.sum()
    wall = max(div(action_ms, @jobs) + 20_000, 45_000)
    finish = DateTime.add(build.start, wall, :millisecond)

    events
    |> Enum.map(fn
      %{payload: {:started, s}} = e ->
        %{
          e
          | payload:
              {:started,
               %{
                 s
                 | uuid: build.id,
                   host: build.host,
                   user: "ci",
                   start_time: timestamp(build.start),
                   start_time_millis: DateTime.to_unix(build.start, :millisecond)
               }}
        }

      %{payload: {:build_metadata, m}} = e ->
        %{e | payload: {:build_metadata, %{m | metadata: Map.put(build.tags, "USER", "ci")}}}

      %{payload: {:workspace_status, ws}} = e ->
        items =
          Enum.map(ws.item, fn
            %{key: "BUILD_HOST"} = item -> %{item | value: build.host}
            %{key: "BUILD_USER"} = item -> %{item | value: "ci"}
            item -> item
          end)

        %{e | payload: {:workspace_status, %{ws | item: items}}}

      %{payload: {:finished, f}} = e ->
        %{
          e
          | payload:
              {:finished,
               %{
                 f
                 | finish_time: timestamp(finish),
                   finish_time_millis: DateTime.to_unix(finish, :millisecond)
               }}
        }

      %{payload: {:build_metrics, %{timing_metrics: %{} = t} = m}} = e ->
        timing = %{
          t
          | wall_time_in_ms: wall,
            execution_phase_time_in_ms: wall - 15_000,
            critical_path_time: %Google.Protobuf.Duration{seconds: div(wall, 2000)}
        }

        %{e | payload: {:build_metrics, %{m | timing_metrics: timing}}}

      e ->
        e
    end)
    |> Fixture.encode_all()
    |> IO.iodata_to_binary()
  end

  defp timestamp(%DateTime{} = at) do
    us = DateTime.to_unix(at, :microsecond)
    %Google.Protobuf.Timestamp{seconds: div(us, 1_000_000), nanos: rem(us, 1_000_000) * 1000}
  end

  # --- uploading -------------------------------------------------------------------------------

  # The event stream is accepted before it is committed: the build may not exist yet.
  defp upload_log(put, path, build, keys, body, attempts) do
    case put.(path, Map.fetch!(keys, build.project), body) do
      404 when attempts > 0 ->
        Process.sleep(100)
        upload_log(put, path, build, keys, body, attempts - 1)

      status ->
        status
    end
  end

  # OTP's client, as everywhere else in the project (Req is not a dependency).
  defp http_put(url, path, key, body) do
    {:ok, _} = Application.ensure_all_started(:inets)

    request =
      {String.to_charlist(url <> path),
       [{~c"x-api-key", String.to_charlist(key)}, {~c"connection", ~c"close"}],
       ~c"application/octet-stream", body}

    case :httpc.request(:put, request, [timeout: 60_000], []) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status < 400 or status == 404 ->
        status

      other ->
        raise "PUT #{url}#{path} failed: #{inspect(other)}; is the server running?"
    end
  end

  # The server's parse queue does the rest; wait until it has.
  defp await_parsed(ids, attempts \\ 600) do
    pending =
      Repo.aggregate(
        from(i in Invocation, where: i.id in ^ids and i.exec_log_status != "parsed"),
        :count
      )

    cond do
      pending == 0 -> :ok
      attempts == 0 -> raise "#{pending} execution logs were not parsed; is the server running?"
      true -> Process.sleep(500) && await_parsed(ids, attempts - 1)
    end
  end
end
