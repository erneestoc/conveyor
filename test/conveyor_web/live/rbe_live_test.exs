defmodule ConveyorWeb.RbeLiveTest do
  use ConveyorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Conveyor.{ExecLog, ExecLogBuilder, Projects, Repo}
  alias Conveyor.Invocations.{Invocation, Metrics}
  alias Conveyor.Rbe.{Groups, Settings}

  setup do
    %{
      project: Projects.ensure_default_project!(),
      t0: DateTime.add(DateTime.utc_now(), -600, :second)
    }
  end

  defp build!(project, start, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invocation{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          status: "succeeded",
          tags: %{"commit" => "abc", "pipeline" => "run-1"},
          host: "ci-1",
          critical_path_ms: 2000,
          execution_ms: 3000,
          inserted_at: start,
          updated_at: start,
          started_at: start,
          finished_at: DateTime.add(start, 20, :second)
        },
        attrs
      )
    )
  end

  defp store!(inv, opts \\ []) do
    {:ok, parsed} =
      [id: inv.id, base: inv.started_at]
      |> Keyword.merge(opts)
      |> ExecLogBuilder.log()
      |> ExecLog.parse()

    ExecLog.store!(inv, parsed)
  end

  test "without logs: the coverage line, how to enable them, and the bound", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    inv = build!(p, t0)

    Repo.insert!(%Metrics{
      invocation_id: inv.id,
      build_metrics: %{
        "actionSummary" => %{
          "runnerCount" => [
            %{"name" => "linux-sandbox", "count" => 8},
            %{"name" => "remote cache hit", "count" => 2}
          ],
          "actionData" => [
            %{
              "mnemonic" => "GoCompilePkg",
              "actionsExecuted" => "10",
              "actionsCreated" => "12",
              "userTime" => "4s"
            }
          ]
        }
      }
    })

    {:ok, view, _html} = live(conn, ~p"/p/#{p.slug}/rbe")

    for id <-
          ~w(rbe-coverage rbe-enable panel-rbe-fleet rbe-fleet-share rbe-fleet-runners rbe-fleet-hosts rbe-fleet-mnemonics rbe-settings rbe-settings-form) do
      assert has_element?(view, "##{id}"), id
    end

    refute has_element?(view, "#rbe-headline")
    assert render(view) =~ "0 of 1 finished builds"
    assert render(view) =~ "GoCompilePkg"
  end

  test "with logs: headline tiles, tables, range, settings", %{conn: conn, project: p, t0: t0} do
    {:ok, p} = Settings.put(p, %{"pipeline_key" => "pipeline"})
    a = build!(p, t0)
    store!(a)

    store!(build!(p, DateTime.add(t0, 200, :millisecond)),
      each: fn s, i -> if i == 5, do: %{s | args: s.args ++ ["--x"]}, else: s end
    )

    store!(build!(p, DateTime.add(t0, 60, :second), %{host: "ci-2"}))

    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/rbe")

    for id <-
          ~w(rbe-headline tile-cache-gap tile-racing tile-cold tile-hit-rate tile-not-remotable tile-parallelism panel-cache-gap gap-same gap-cross gap-total panel-rbe-mnemonics mnemonic-TestRunner panel-rbe-targets rbe-target-0 panel-rbe-pipelines panel-rbe-near rbe-near-0 rbe-fallback-keys panel-rbe-fleet) do
      assert has_element?(view, "##{id}"), id
    end

    refute has_element?(view, "#panel-rbe-projects")
    html = render(view)
    assert html =~ "3 of 3 finished builds"
    assert view |> element("#gap-total") |> render() =~ "6.0s"
    assert view |> element("#tile-parallelism") |> render() =~ "3.0×"

    view |> element("#rbe-range-24h") |> render_click()
    assert_patch(view, ~p"/p/#{p.slug}/rbe?range=24h")
    assert has_element?(view, "#rbe-range-24h[aria-selected=true]")

    view
    |> form("#rbe-settings-form", %{
      "cores" => "TestRunner=4",
      "tolerance_s" => "5",
      "cache_group" => "mono"
    })
    |> render_submit()

    p = Projects.get_project!(p.id)
    assert Settings.get(p).cores == %{"TestRunner" => 4.0}
    assert Groups.name(p) == "mono"
    assert has_element?(view, "#rbe-group-link")
    assert view |> element("#mnemonic-TestRunner") |> render() =~ "project setting"

    view |> form("#rbe-settings-form", %{"cores" => "nonsense"}) |> render_submit()
    assert render(view) =~ "cores must look like"
  end

  test "a cache group: its page, its projects, and the JSON of each", %{
    conn: conn,
    project: p,
    t0: t0
  } do
    {:ok, other} = Projects.create_project(%{slug: "other-app", name: "Other app"})
    {:ok, p} = Groups.put(p, "mono")
    {:ok, other} = Groups.put(other, "mono")
    store!(build!(p, t0))
    store!(build!(other, DateTime.add(t0, 60, :second)))

    {:ok, view, _} = live(conn, ~p"/groups/mono/rbe")
    assert has_element?(view, "#panel-rbe-projects")
    assert has_element?(view, "#rbe-project-#{other.id}")
    assert has_element?(view, "#rbe-from-#{other.id}")
    assert view |> element("#rbe-subtitle") |> render() =~ "2 projects"
    assert view |> element("#gap-cross") |> render() =~ "6.0s"
    refute has_element?(view, "#rbe-settings")

    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/groups/nope/rbe") end
    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/groups/nope/rbe/json") end
    assert_raise ConveyorWeb.NotFoundError, fn -> get(conn, ~p"/p/nope/rbe/json") end

    assert %{
             "range" => "7d",
             "report" => %{"cache" => %{"cross_project" => %{"n" => 12}}, "members" => 2}
           } =
             conn |> get(~p"/groups/mono/rbe/json") |> json_response(200)

    assert %{"range" => "24h", "report" => %{"cache" => %{"gap" => %{"ms" => 6000}}}} =
             conn |> get(~p"/p/#{other.slug}/rbe/json?range=24h") |> json_response(200)

    # an API key reads its own project; the other project of the group has no name there
    {:ok, _, key} = Projects.create_api_key(other, %{name: "reader", scopes: ["read"]})

    body =
      build_conn()
      |> put_req_header("x-api-key", key)
      |> get(~p"/api/v1/rbe")
      |> json_response(200)

    assert [%{"name" => "Other app", "from" => [%{"name" => "other projects", "id" => nil}]}] =
             body["report"]["projects"]["rows"]

    refute inspect(body) =~ "Default"
    assert build_conn() |> get(~p"/api/v1/rbe") |> json_response(401)
  end
end
