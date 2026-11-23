defmodule Conveyor.Seed.StreamDemo do
  @moduledoc """
  Demo data for the Duplicate work pages in event-stream mode
  (`mix conveyor.seed --stream-demo`): the recorded builds of `test/fixtures/stream`
  (Bazel 9.2 with `--build_event_publish_all_actions`), moved in time and tagged with a
  commit, replayed through the real gRPC ingest of a running server. The server must
  accept API keys (`BES_INGEST_AUTH=api_key`; the dev default sends everything to the
  project `default`).

  What it makes (slugs start with `stream-demo-`; a second run replaces the first):

    * `stream-demo-ios`: shards of one commit (two machines racing, then two one after
      the other) and a Bazel 8.4 build that is counted only;
    * `stream-demo-go-api` and `stream-demo-go-web` in the cache group
      `stream-demo-monorepo`: a first commit, a second one on the machine that built the
      first (hits across commits and re-runs: the evidence for the estimate), the second
      commit on a cold machine in the other project, and a build without a commit;
    * `stream-demo-both`: two builds that also upload their execution log (reported from
      the log; at their recorded times) and one reported from the stream.

  Also the home of the fixture helpers the tests and the scale bench use (`events/2`).
  """
  import Ecto.Query

  alias Conveyor.Bep.{Fixture, Replay}
  alias Conveyor.ExecLog.ActionKey
  alias Conveyor.Invocations.Invocation
  alias Conveyor.{Projects, Repo}
  alias Conveyor.Rbe.{Groups, Settings}

  @dir "test/fixtures/stream"
  @group "stream-demo-monorepo"
  @key_name "stream demo"

  @doc "The path of a recorded stream (`\"bep\"`) or of its execution log (`\"log\"`)."
  @spec path(String.t(), String.t()) :: Path.t()
  def path(name, ext), do: Path.join([File.cwd!(), @dir, "#{name}.#{ext}.zst"])

  @doc """
  The events of a recorded stream. `:shift_us` moves the build in time (its start, its
  actions' times, its finish), `:hits_shift_us` its cache hits (the times of the build
  they were served from; by default with the build); `:tags` are what `--build_metadata`
  would have added.
  """
  @spec events(String.t(), keyword()) :: [BuildEventStream.BuildEvent.t()]
  def events(name, opts \\ []) do
    shift = Keyword.get(opts, :shift_us, 0)
    hits_shift = Keyword.get(opts, :hits_shift_us, shift)
    tags = Keyword.get(opts, :tags, %{})
    events = name |> path("bep") |> Fixture.read!()

    started =
      Enum.find_value(events, fn
        %{payload: {:started, s}} -> s.start_time
        _ -> nil
      end)

    Enum.map(events, fn
      # Bazel always sends this event; `--build_metadata` fills it.
      %{payload: {:build_metadata, m}} = e ->
        %{e | payload: {:build_metadata, %{m | metadata: Map.merge(m.metadata, tags)}}}

      # A cache hit carries the times of the build that filled the cache.
      %{payload: {:action, %{start_time: %{} = at}}} = e
      when {at.seconds, at.nanos} < {started.seconds, started.nanos} ->
        shift(e, hits_shift)

      e ->
        shift(e, shift)
    end)
  end

  @doc "When the recorded build started (`BuildStarted.start_time`)."
  @spec started_at(String.t()) :: DateTime.t()
  def started_at(name) do
    name
    |> path("bep")
    |> Fixture.read!()
    |> Enum.find_value(fn
      %{payload: {:started, s}} -> Conveyor.Bep.Event.to_datetime(s.start_time)
      _ -> nil
    end)
  end

  defp shift(event, 0), do: event

  defp shift(%{payload: {:started, s}} = e, us),
    do: %{e | payload: {:started, %{s | start_time: ts(s.start_time, us)}}}

  defp shift(%{payload: {:finished, f}} = e, us),
    do: %{e | payload: {:finished, %{f | finish_time: ts(f.finish_time, us)}}}

  defp shift(%{payload: {:action, a}} = e, us),
    do: %{
      e
      | payload: {:action, %{a | start_time: ts(a.start_time, us), end_time: ts(a.end_time, us)}}
    }

  defp shift(event, _us), do: event

  defp ts(nil, _us), do: nil

  defp ts(%{seconds: s, nanos: n}, us) do
    total = s * 1_000_000_000 + n + us * 1_000

    %Google.Protobuf.Timestamp{
      seconds: Integer.floor_div(total, 1_000_000_000),
      nanos: Integer.mod(total, 1_000_000_000)
    }
  end

  # --- the demo ------------------------------------------------------------------------------

  # {project, fixture, minutes after the base (nil: as recorded), commit, hits from (the
  # minutes of the build whose cache it read), upload the log?}
  @builds [
    {"stream-demo-ios", "abseil_a1", 0, "5f1c2aa", nil, false},
    {"stream-demo-ios", "abseil_b1", 0.12, "5f1c2aa", nil, false},
    {"stream-demo-ios", "buildtools_a1", 40, "9be07d3", nil, false},
    {"stream-demo-ios", "buildtools_b1", 50, "9be07d3", nil, false},
    {"stream-demo-ios", "bazel_8_4", 55, "9be07d3", nil, false},
    {"stream-demo-go-api", "buildtools_a1", 0, "a41e9c0", nil, false},
    {"stream-demo-go-api", "buildtools_a2", 12, "c77d512", 0, false},
    {"stream-demo-go-web", "buildtools_b1", 25, "c77d512", nil, false},
    {"stream-demo-go-web", "buildtools_a1_warm", 35, nil, 0, false},
    {"stream-demo-both", "abseil_a1", nil, "5f1c2aa", nil, true},
    {"stream-demo-both", "abseil_b1", nil, "5f1c2aa", nil, true},
    {"stream-demo-both", "abseil_b2", 30, "d02b6e4", nil, false}
  ]

  @doc """
  Seeds the demo. Options: `:grpc` (`"host:port"` of the running server's BES endpoint,
  default `localhost:1985`), `:url` (its web endpoint, for the execution logs, default
  `http://localhost:4100`), `:now`, and for tests `:put` and `:await`. Returns the builds
  per project slug.
  """
  @spec run(keyword()) :: %{String.t() => non_neg_integer()}
  def run(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:grpc)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    [host, port] = opts |> Keyword.get(:grpc, "localhost:1985") |> String.split(":")
    url = Keyword.get(opts, :url, "http://localhost:4100")
    put = Keyword.get(opts, :put, &put/4)
    await = Keyword.get(opts, :await, &await/1)
    # Three hours ago, on the hour: inside every retention, in hours not yet final.
    base = %{DateTime.add(now, -3 * 3600, :second) | minute: 0, second: 0, microsecond: {0, 6}}
    keys = @builds |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Map.new(&{&1, reset!(&1)})

    ids =
      for {slug, name, minutes, commit, hits_from, log?} <- @builds do
        shift = shift_us(base, name, minutes)
        # The build its hits were served from is the first of its project's group.
        hits = if hits_from, do: shift_us(base, "buildtools_a1", hits_from), else: shift
        tags = if commit, do: %{"COMMIT_SHA" => commit}, else: %{}
        events = events(name, shift_us: shift, hits_shift_us: hits, tags: tags)
        id = Replay.uuid()

        {:ok, _} =
          Replay.run(events,
            host: host,
            port: String.to_integer(port),
            api_key: Map.fetch!(keys, slug),
            invocation_id: id
          )

        if log? do
          201 =
            put.(url, "/api/v1/invocations/#{id}/artifacts/execution.log.zst", keys[slug], name)
        end

        id
      end

    await.(ids)
    @builds |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
  end

  defp shift_us(_base, _name, nil), do: 0

  defp shift_us(base, name, minutes),
    do:
      base
      |> DateTime.add(round(minutes * 60), :second)
      |> DateTime.diff(started_at(name), :microsecond)

  # The project as a fresh one, with a key that may ingest and upload.
  defp reset!(slug) do
    project =
      Projects.get_project_by_slug(slug) ||
        elem(Projects.create_project(%{slug: slug, name: name(slug)}), 1)

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

    {:ok, _} =
      Settings.put(project, %{
        "cores" => "",
        "pipeline_key" => "",
        "tolerance_s" => "2",
        "cores_properties" => "",
        "cores_unit" => "auto"
      })

    {:ok, _key, plaintext} =
      Projects.create_api_key(project, %{name: @key_name, scopes: ["ingest", "upload"]})

    plaintext
  end

  defp name("stream-demo-ios"), do: "Stream demo iOS (shards, one commit)"
  defp name("stream-demo-go-api"), do: "Stream demo Go api"
  defp name("stream-demo-go-web"), do: "Stream demo Go web"
  defp name("stream-demo-both"), do: "Stream demo, logs and stream"

  defp put(url, path, key, name) do
    {:ok, _} = Application.ensure_all_started(:inets)

    request =
      {String.to_charlist(url <> path),
       [{~c"x-api-key", String.to_charlist(key)}, {~c"connection", ~c"close"}],
       ~c"application/octet-stream", File.read!(path(name, "log"))}

    case :httpc.request(:put, request, [timeout: 60_000], []) do
      {:ok, {{_version, status, _reason}, _headers, _body}} -> status
      other -> raise "PUT #{url}#{path} failed: #{inspect(other)}; is the server running?"
    end
  end

  # The server merges the keys when a build ends and parses the logs; wait for both.
  defp await(ids, attempts \\ 240) do
    pending =
      Repo.aggregate(
        from(i in Invocation,
          where: i.id in ^ids,
          where:
            (i.stream_actions > 0 and is_nil(i.stream_keys_at)) or
              i.exec_log_status == "available"
        ),
        :count
      )

    cond do
      pending == 0 -> :ok
      attempts == 0 -> raise "#{pending} builds were not merged or parsed; is the server running?"
      true -> Process.sleep(500) && await(ids, attempts - 1)
    end
  end
end
