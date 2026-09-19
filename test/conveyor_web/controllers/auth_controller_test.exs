defmodule ConveyorWeb.AuthControllerTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.{FakeOidc, Projects}

  setup_all do
    %{issuer: FakeOidc.start()}
  end

  setup do
    previous = Application.get_env(:conveyor, Conveyor.Accounts)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Accounts, previous) end)
    %{previous: previous}
  end

  defp configure(overrides, previous),
    do: Application.put_env(:conveyor, Conveyor.Accounts, Keyword.merge(previous, overrides))

  defp oidc_config(issuer, prev, extra \\ []) do
    configure(
      [
        mode: :oidc,
        oidc: [
          client_id: FakeOidc.client_id(),
          client_secret: FakeOidc.client_secret(),
          base_url: issuer
        ]
      ] ++ extra,
      prev
    )
  end

  # Drives the browser side of the flow: /auth/oidc → provider → /auth/oidc/callback.
  defp sign_in(conn) do
    conn = get(conn, ~p"/auth/oidc")
    [location] = get_resp_header(conn, "location")
    assert location =~ "/authorize?"

    {:ok, {{_, 302, _}, headers, _}} =
      :httpc.request(:get, {String.to_charlist(location), []}, [autoredirect: false], [])

    {_, back} = List.keyfind(headers, ~c"location", 0)
    %URI{query: query} = URI.parse(List.to_string(back))
    get(conn, ~p"/auth/oidc/callback?#{URI.decode_query(query)}")
  end

  test "open mode without a token: settings open, no sign-in UI", %{conn: conn} do
    conn = get(conn, ~p"/auth/login")
    assert html_response(conn, 200) =~ "open mode"
    assert html_response(conn, 200) =~ "No <code"
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "#nav-settings")
    refute has_element?(view, "#nav-logout")
    conn = delete(build_conn(), ~p"/auth/logout")
    assert redirected_to(conn) == "/"
  end

  test "open mode with ADMIN_TOKEN gates settings", %{conn: conn, previous: prev} do
    configure([admin_token: "open-sesame"], prev)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings")
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#nav-settings")
    assert has_element?(view, "#nav-admin-login")

    conn = get(conn, ~p"/auth/login")
    assert html_response(conn, 200) =~ "admin-token-form"

    conn = post(build_conn(), ~p"/auth/admin", %{"token" => "wrong"})
    assert redirected_to(conn) == "/auth/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid"

    conn = post(build_conn(), ~p"/auth/admin", %{"token" => "open-sesame"})
    assert redirected_to(conn) == "/settings"
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "#nav-logout")
    conn = delete(conn, ~p"/auth/logout")
    assert redirected_to(conn) == "/"
    assert {:error, {:redirect, _}} = live(conn, ~p"/settings")
  end

  test "oidc mode signs users in through the provider", %{
    conn: conn,
    issuer: issuer,
    previous: prev
  } do
    oidc_config(issuer, prev, admin_emails: ["admin@example.com"])
    FakeOidc.set_claims(%{"sub" => "u1", "email" => "dev@example.com", "groups" => ["team-a"]})

    # Everything redirects to the login page until signed in.
    conn = get(conn, ~p"/p/default/dashboard")
    assert redirected_to(conn) == "/auth/login"
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), ~p"/")
    login = get(build_conn(), ~p"/auth/login")
    assert html_response(login, 200) =~ "oidc-login"

    conn = sign_in(conn)
    assert redirected_to(conn) == "/p/default/dashboard"
    assert get_session(conn, :user_id)

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#nav-user", "dev@example.com")
    refute has_element?(view, "#nav-settings")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings")

    # Project visibility by group.
    {:ok, hidden} = Projects.create_project(%{slug: "hidden", name: "Hidden"})
    {:ok, _} = Projects.put_allowed_groups(hidden, ["team-b"])
    {:ok, shown} = Projects.create_project(%{slug: "shown", name: "Shown"})
    {:ok, _} = Projects.put_allowed_groups(shown, ["team-a"])
    {:ok, view, _} = live(conn, ~p"/p/shown")
    refute render(view) =~ "Hidden"
    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/p/hidden") end

    id =
      ingest_fixture!("analysis_failure", %{
        context()
        | project_id: hidden.id,
          project_slug: "hidden"
      })

    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/invocation/#{id}") end

    assert_raise ConveyorWeb.NotFoundError, fn ->
      get(conn, ~p"/invocation/#{id}/download/log")
    end

    # Admins see everything and the settings page.
    FakeOidc.set_claims(%{"sub" => "u2", "email" => "admin@example.com"})
    admin_conn = sign_in(build_conn())
    assert redirected_to(admin_conn) == "/"
    {:ok, view, _} = live(admin_conn, ~p"/settings")
    assert has_element?(view, "#nav-settings")
    assert render(view) =~ "Hidden"
    {:ok, _view, _} = live(admin_conn, ~p"/invocation/#{id}")
    assert get(admin_conn, ~p"/invocation/#{id}/download/log") |> response(200)

    view
    |> form("#allowed-groups-form-#{hidden.id}", %{"groups" => "team-a, team-c"})
    |> render_submit()

    assert Projects.allowed_groups(Projects.get_project!(hidden.id)) == ["team-a", "team-c"]

    conn = delete(conn, ~p"/auth/logout")
    assert redirected_to(conn) == "/auth/login"
    assert {:error, {:redirect, _}} = live(conn, ~p"/")
  end

  test "oidc failures are reported on the login page", %{
    conn: conn,
    issuer: issuer,
    previous: prev
  } do
    oidc_config(issuer, prev, allowed_email_domains: ["example.com"])
    FakeOidc.set_claims(%{"sub" => "u3", "email" => "someone@evil.com"})
    conn = sign_in(conn)
    assert redirected_to(conn) == "/auth/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "domain is not allowed"

    FakeOidc.set_claims(%{"sub" => "u4", "email" => nil})
    conn = sign_in(build_conn())
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no email"

    # Wrong state / missing session params.
    conn = get(build_conn(), ~p"/auth/oidc/callback?code=x&state=y")
    assert redirected_to(conn) == "/auth/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in failed"

    # Provider unreachable.
    oidc_config("http://127.0.0.1:1", prev)
    conn = get(build_conn(), ~p"/auth/oidc")
    assert redirected_to(conn) == "/auth/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not start sign-in"

    assert ConveyorWeb.Plugs.Auth.safe_return_to("//evil.com") == "/"
    assert ConveyorWeb.Plugs.Auth.safe_return_to("https://evil.com") == "/"
    assert ConveyorWeb.Plugs.Auth.safe_return_to("/tests") == "/tests"
  end
end
