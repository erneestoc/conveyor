defmodule ConveyorWeb.RbeCoresLiveTest do
  @moduledoc """
  The cores declaration on the Duplicate work page (PLAN §27.7): the form, the property names seen
  in logs, reading stored logs again, the coverage line, and who may read any of it.
  """
  use ConveyorWeb.ConnCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  import Phoenix.LiveViewTest

  alias Conveyor.{Artifacts, Blobs, ExecLog, ExecLogBuilder, FakeOidc, Projects, Repo}
  alias Conveyor.ExecLog.Properties
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Rbe.{Groups, Settings}
  alias Conveyor.Workers.ParseExecLog

  setup_all do
    %{issuer: FakeOidc.start()}
  end

  setup do
    %{
      project: Projects.ensure_default_project!(),
      t0: DateTime.add(DateTime.utc_now(), -600, :second)
    }
  end

  # A parsed build whose spawns carry platform properties, with its log attached.
  defp build_with_log!(project, start, properties) do
    inv =
      Repo.insert!(%Invocation{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        status: "succeeded",
        tags: %{},
        inserted_at: start,
        updated_at: start,
        started_at: start,
        finished_at: DateTime.add(start, 20, :second)
      })

    binary =
      ExecLogBuilder.log(
        id: inv.id,
        base: start,
        each: fn s, _ -> ExecLogBuilder.platform(s, properties) end
      )

    {:ok, parsed} = ExecLog.parse(binary)
    ExecLog.store!(inv, parsed)
    {:ok, blob} = Blobs.put(project, binary)
    Artifacts.attach(inv, "execution.log.zst", blob, "upload")
    inv
  end

  defp oidc(issuer) do
    previous = Application.get_env(:conveyor, Conveyor.Accounts)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Accounts, previous) end)

    Application.put_env(
      :conveyor,
      Conveyor.Accounts,
      Keyword.merge(previous,
        mode: :oidc,
        oidc: [
          client_id: FakeOidc.client_id(),
          client_secret: FakeOidc.client_secret(),
          base_url: issuer
        ]
      )
    )
  end

  defp sign_in(claims) do
    FakeOidc.set_claims(claims)
    conn = get(build_conn(), ~p"/auth/oidc")
    [location] = get_resp_header(conn, "location")

    {:ok, {{_, 302, _}, headers, _}} =
      :httpc.request(:get, {String.to_charlist(location), []}, [autoredirect: false], [])

    {_, back} = List.keyfind(headers, ~c"location", 0)
    %URI{query: query} = URI.parse(List.to_string(back))
    get(conn, ~p"/auth/oidc/callback?#{URI.decode_query(query)}")
  end

  test "the declaration: saved, validated, audited, and said to apply to logs parsed afterwards",
       %{conn: conn, project: p, t0: t0} do
    build_with_log!(p, t0, %{"runner-cores" => "3000", "OSFamily" => "macos"})
    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")

    for id <-
          ~w(rbe-cores-property rbe-cores-property-note rbe-properties rbe-property-0 rbe-reread rbe-reread-button rbe-cores-coverage rbe-cores-names rbe-cores-coverage-count) do
      assert has_element?(view, "##{id}"), id
    end

    assert view |> element("#rbe-cores-property-note") |> render() =~ "logs parsed from now on"

    assert has_element?(
             view,
             "#rbe-settings-form input[name=cores_properties][value*='EstimatedCPU']"
           )

    # nothing states its cores under the built-in names
    assert view |> element("#rbe-cores-coverage") |> render() =~ "0.0% of executed wall time"
    assert view |> element("#rbe-cores-coverage") |> render() =~ "0 of 12 executions"
    assert view |> element("#rbe-properties") |> render() =~ "runner-cores"
    assert view |> element("#rbe-properties") |> render() =~ "3000"

    view
    |> form("#rbe-settings-form", %{
      "cores_properties" => "runner-cores, Cores",
      "cores_unit" => "millicores"
    })
    |> render_submit()

    assert Settings.get(Projects.get_project!(p.id)).cores_property ==
             %{names: ["runner-cores", "Cores"], unit: "millicores"}

    assert [
             %{
               action: "project.rbe_settings",
               metadata: %{
                 "cores_properties" => "runner-cores, Cores",
                 "cores_unit" => "millicores"
               }
             }
           ] = Conveyor.Audit.recent(1)

    assert view |> element("#rbe-cores-names") |> render() =~ "runner-cores, Cores"

    assert has_element?(
             view,
             "#rbe-settings-form input[name=cores_properties][value='runner-cores, Cores']"
           )

    assert has_element?(
             view,
             "#rbe-settings-form select[name=cores_unit] option[value=millicores][selected]"
           )

    # the build already parsed keeps what it had
    assert view |> element("#rbe-cores-coverage") |> render() =~ "0 of 12 executions"

    view |> form("#rbe-settings-form", %{"cores_properties" => "a,,b"}) |> render_submit()
    assert render(view) =~ "exec property names"

    assert Settings.get(Projects.get_project!(p.id)).cores_property.names ==
             ["runner-cores", "Cores"]
  end

  test "reading stored logs again: the count on the button, the jobs, the audit entry, the result",
       %{conn: conn, project: p, t0: t0} do
    a = build_with_log!(p, t0, %{"runner-cores" => "3000"})
    b = build_with_log!(p, DateTime.add(t0, 60, :second), %{"runner-cores" => "3000"})

    {:ok, _} =
      Settings.put(p, %{"cores_properties" => "runner-cores", "cores_unit" => "millicores"})

    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    button = element(view, "#rbe-reread-button")
    assert render(button) =~ "Re-read cores from stored logs (2 builds)"
    assert render(button) =~ "data-confirm"
    refute has_element?(view, "#rbe-reread-button[disabled]")

    render_click(button)
    assert render(view) =~ "Reading 2 stored logs again"

    jobs = all_enqueued(worker: ParseExecLog)
    assert Enum.sort(Enum.map(jobs, & &1.args["invocation_id"])) == Enum.sort([a.id, b.id])

    assert [
             %{
               action: "project.rbe_reread",
               metadata: %{
                 "builds" => 2,
                 "range" => "7d",
                 "cores_properties" => "runner-cores",
                 "cores_unit" => "millicores"
               }
             }
           ] = Conveyor.Audit.recent(1)

    assert %{success: 2} = Oban.drain_queue(queue: :parse)
    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    assert view |> element("#rbe-cores-coverage") |> render() =~ "100.0% of executed wall time"
    assert view |> element("#rbe-cores-coverage") |> render() =~ "24 of 24 executions"
  end

  test "no stored logs: the button is disabled and no names are listed", %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, ~p"/p/#{p.slug}/duplicate-work")
    assert has_element?(view, "#rbe-properties-empty")
    assert has_element?(view, "#rbe-reread-button[disabled]")
    assert view |> element("#rbe-reread-button") |> render() =~ "(0 builds)"
    refute has_element?(view, "#rbe-cores-coverage")
  end

  describe "tenancy" do
    setup %{issuer: issuer, t0: t0} do
      oidc(issuer)
      {:ok, alpha} = Projects.create_project(%{slug: "alpha", name: "Alpha"})
      {:ok, alpha} = Projects.put_allowed_groups(alpha, ["alpha"])
      {:ok, alpha} = Projects.put_admin_groups(alpha, ["alpha-leads"])
      {:ok, beta} = Projects.create_project(%{slug: "beta", name: "Beta"})
      {:ok, beta} = Projects.put_allowed_groups(beta, ["beta"])
      {:ok, alpha} = Groups.put(alpha, "mono")
      {:ok, beta} = Groups.put(beta, "mono")
      build_with_log!(alpha, t0, %{"alpha-only-pool" => "big", "cores" => "2"})
      build_with_log!(beta, DateTime.add(t0, 60, :second), %{"beta-pool" => "small"})
      %{alpha: alpha, beta: beta}
    end

    test "a viewer without access to a project reads none of its property names", %{alpha: alpha} do
      assert [_ | _] = Properties.list(alpha.id)
      conn = sign_in(%{"sub" => "b", "email" => "b@example.com", "groups" => ["beta"]})

      assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/p/alpha/duplicate-work") end

      assert_raise ConveyorWeb.NotFoundError, fn ->
        get(conn, ~p"/p/alpha/duplicate-work/json")
      end

      # the group both projects share, and the viewer's own project: no name of alpha's
      {:ok, view, _} = live(conn, ~p"/groups/mono/duplicate-work")
      refute render(view) =~ "alpha-only-pool"
      refute has_element?(view, "#rbe-properties")
      refute has_element?(view, "#rbe-cores-names")
      assert has_element?(view, "#rbe-cores-coverage")

      for path <- [~p"/groups/mono/duplicate-work/json", ~p"/p/beta/duplicate-work/json"] do
        body = conn |> get(path) |> json_response(200)
        refute inspect(body) =~ "alpha-only-pool"
        assert %{"exact" => _, "executed" => _} = body["report"]["cores_coverage"]
      end

      {:ok, view, _} = live(conn, ~p"/p/beta/duplicate-work")
      refute render(view) =~ "alpha-only-pool"
    end

    test "a project's viewer sees the coverage, not the names seen nor the controls; its admin sees all",
         %{alpha: alpha} do
      conn = sign_in(%{"sub" => "a", "email" => "a@example.com", "groups" => ["alpha"]})
      {:ok, view, _} = live(conn, ~p"/p/alpha/duplicate-work")
      assert has_element?(view, "#rbe-cores-coverage")
      refute has_element?(view, "#rbe-settings")
      refute has_element?(view, "#rbe-properties")
      refute has_element?(view, "#rbe-reread-button")
      refute render(view) =~ "alpha-only-pool"
      refute conn |> get(~p"/p/alpha/duplicate-work/json") |> response(200) =~ "alpha-only-pool"

      # the events are refused too, not only hidden
      render_click(view, "reread", %{})
      render_submit(view, "save", %{"cores" => "", "cores_unit" => "millicores"})
      assert all_enqueued(worker: ParseExecLog) == []
      assert Settings.get(Projects.get_project!(alpha.id)).cores_property.unit == "auto"

      lead =
        sign_in(%{"sub" => "l", "email" => "l@example.com", "groups" => ["alpha", "alpha-leads"]})

      {:ok, view, _} = live(lead, ~p"/p/alpha/duplicate-work")
      assert view |> element("#rbe-properties") |> render() =~ "alpha-only-pool"
      refute render(view) =~ "beta-pool"
      assert view |> element("#rbe-reread-button") |> render() =~ "(1 builds)"
    end
  end
end
