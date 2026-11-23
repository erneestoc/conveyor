defmodule ConveyorWeb.RbeStreamLiveTest do
  @moduledoc """
  The Duplicate work page for builds that sent per-action events and no execution log:
  the source line, the two headline classes with their three figures, the tables, the
  setup in the settings panel, and a cache group with the tenancy of the log figures.
  """
  use ConveyorWeb.ConnCase, async: false

  use Oban.Testing, repo: Conveyor.Repo

  import Phoenix.LiveViewTest

  alias Conveyor.Invocations.Invocation
  alias Conveyor.Metrics.Scope
  alias Conveyor.{Projects, Repo}
  alias Conveyor.Rbe.{Groups, Report, Settings, Stream, StreamActions, StreamChunk}

  setup do
    %{
      project: Projects.ensure_default_project!(),
      t0: DateTime.add(DateTime.utc_now(), -900, :second)
    }
  end

  # A finished build with one chunk: `actions` are `{label, start offset s, seconds}`,
  # or `{:hit, label, origin}` (a hit served from the execution that started at `origin`).
  defp build!(project, t0, offset, commit, actions) do
    start = DateTime.add(t0, offset, :second)
    us = DateTime.to_unix(start, :microsecond)

    inv =
      Repo.insert!(%Invocation{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        status: "succeeded",
        tags: if(commit, do: %{"commit" => commit}, else: %{}),
        inserted_at: start,
        updated_at: start,
        started_at: start,
        last_event_at: start,
        finished_at: DateTime.add(start, 20, :second),
        stream_actions: length(actions)
      })

    records =
      for {action, seq} <- Enum.with_index(actions, 2) do
        {label, from, seconds} =
          case action do
            {:hit, label, origin} -> {label, origin, 2}
            {label, at, seconds} -> {label, us + at * 1_000_000, seconds}
          end

        StreamActions.record(
          label,
          "Compile",
          label,
          ["cc"],
          from,
          from + seconds * 1_000_000,
          us,
          seq
        )
      end

    Repo.insert!(%StreamChunk{
      invocation_id: inv.id,
      first_seq: 2,
      day: DateTime.to_date(start),
      n: length(records),
      records: StreamActions.encode(records)
    })

    us
  end

  test "a project reported from the event stream alone", %{conn: conn, project: p, t0: t0} do
    # c1 twice (a same-commit duplicate), then c2 on a machine that read the first
    # build's cache (a hit, and a re-run of //a:y: changed), then c2 cold.
    first = build!(p, t0, 0, "c1", [{"//a:x", 1, 2}, {"//a:y", 4, 2}])
    build!(p, t0, 60, "c1", [{"//a:x", 1, 2}])
    build!(p, t0, 120, "c2", [{:hit, "//a:x", first + 1_000_000}, {"//a:y", 1, 3}])
    build!(p, t0, 180, "c2", [{"//a:x", 1, 4}])
    build!(p, t0, 240, nil, [{"//a:z", 1, 1}])
    assert Stream.merge_pending!(DateTime.add(t0, -60, :second)) == 5

    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    assert view |> element("#rbe-source") |> render() =~ "the event stream"
    assert view |> element("#rbe-stream-source") |> render() =~ "5 of 5"
    assert has_element?(view, "#rbe-stream-no-commit")
    refute has_element?(view, "#rbe-empty")
    refute has_element?(view, "#rbe-headline")

    for id <-
          ~w(rbe-stream tile-stream-sequential tile-stream-sequential-value tile-stream-sequential-same tile-stream-sequential-any tile-stream-racing tile-stream-hit-rate stream-hit-rate-today tile-stream-executed tile-stream-evidence panel-stream-mnemonics stream-mnemonic-Compile panel-stream-targets stream-target-0 rbe-settings rbe-stream-setup rbe-stream-setup-text rbe-stream-setup-commit rbe-exact-mode rbe-ci-snippet) do
      assert has_element?(view, "##{id}"), "missing ##{id}"
    end

    assert has_element?(view, "#tile-stream-sequential-kind", "estimate")

    assert view |> element("#rbe-stream-setup-text") |> render() =~
             "--build_event_publish_all_actions"

    assert view |> element("#rbe-stream-setup-tags") |> render() =~ "commit_sha"

    assert %{"report" => %{"source" => "stream", "stream" => s}} =
             conn |> get(~p"/p/#{p.slug}/duplicate-work/json") |> json_response(200)

    # Same commit: the second build's //a:x. Any commit: also //a:y and //a:x at c2.
    assert %{"sequential" => %{"n" => 1, "ms" => 2000}} = s["same_commit"]
    assert %{"sequential" => %{"n" => 3, "ms" => 9000}} = s["any_commit"]
    # //a:y is proven different; //a:x at c2 is unknown, and the one observation says
    # half of the actions are unchanged (by count; by time 2 s of 5 s).
    assert %{
             "sequential" => %{"n" => n, "ms" => 3600},
             "evidence" => %{
               "unchanged" => %{"n" => 1},
               "different" => %{"n" => 1},
               "unknown" => %{"n" => 1}
             }
           } = s["estimate"]

    assert n in [1, 2]
    assert s["no_commit_builds"] == 1 and s["days"] >= 1
    assert %{"today" => today, "perfect_cache" => [same, any]} = s["hit_rate"]
    assert today < same and same < any
    assert [%{"mnemonic" => "Compile", "hits" => 1}] = s["mnemonics"]
    assert Enum.map(s["targets"], & &1["target"]) == ["//a:x", "//a:y"]
  end

  test "pending builds are stated; a merge at the end of the build clears them", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    build!(p, t0, 0, "c1", [{"//a:x", 1, 2}])
    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    assert has_element?(view, "#rbe-stream-pending")
    assert has_element?(view, "#rbe-empty")
    assert has_element?(view, "#rbe-stream-setup-empty")
    assert has_element?(view, "#rbe-exact-mode-empty #rbe-ci-snippet-empty")

    [inv] = Repo.all(Invocation)
    assert :ok = perform_job(Conveyor.Workers.StreamKeys, %{invocation_id: inv.id})
    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    refute has_element?(view, "#rbe-stream-pending")
    assert has_element?(view, "#rbe-stream")
  end

  test "a cache group: the same figures, and only visible projects' targets", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    {:ok, other} = Projects.create_project(%{slug: "other-app", name: "Other app"})
    {:ok, p} = Groups.put(p, "mono")
    {:ok, other} = Groups.put(other, "mono")
    build!(p, t0, 0, "c1", [{"//secret:lib", 1, 2}, {"//secret:only", 4, 2}])
    build!(p, t0, 60, "c1", [{"//secret:only", 1, 2}])
    build!(other, t0, 120, "c1", [{"//secret:lib", 1, 2}])
    assert Stream.merge_pending!(DateTime.add(t0, -60, :second)) == 3

    {:ok, view, _} = live(conn, ~p"/groups/mono/duplicate-work")
    assert has_element?(view, "#rbe-stream")
    assert has_element?(view, "#tile-stream-sequential-kind", "same at any commit")
    assert has_element?(view, "#panel-stream-targets", "Other app")
    refute has_element?(view, "#rbe-stream-setup")

    assert %{"report" => %{"stream" => %{"same_commit" => same}}} =
             conn |> get(~p"/groups/mono/duplicate-work/json") |> json_response(200)

    assert %{"sequential" => %{"n" => 2}, "cross_project" => %{"n" => 1}} = same

    # A viewer of the other project only: the sums are the group's, the targets its own.
    scope =
      "24h" |> Scope.new(nil) |> Scope.restrict([p.id, other.id]) |> Map.put(:stored, false)

    report =
      Report.build(scope,
        settings: Settings.get(other),
        visible: [other.id],
        names: %{other.id => other.name}
      )

    assert report.stream.same_commit.sequential.n == 2
    assert [%{project: "Other app", target: "//secret:lib"}] = report.stream.targets
    refute inspect(report.stream) =~ "//secret:only"

    # An API key reads its own project.
    {:ok, _, key} = Projects.create_api_key(other, %{name: "reader", scopes: ["read"]})

    body =
      build_conn()
      |> put_req_header("x-api-key", key)
      |> get(~p"/api/v1/duplicate-work")
      |> json_response(200)

    assert body["report"]["stream"]["builds"] == 1
    refute inspect(body) =~ "//secret:only"
  end
end
