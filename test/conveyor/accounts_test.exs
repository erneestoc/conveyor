defmodule Conveyor.AccountsTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Accounts
  alias Conveyor.Accounts.Scope
  alias Conveyor.Projects

  setup do
    previous = Application.get_env(:conveyor, Conveyor.Accounts)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Accounts, previous) end)
    %{previous: previous}
  end

  defp configure(overrides, previous),
    do: Application.put_env(:conveyor, Conveyor.Accounts, Keyword.merge(previous, overrides))

  test "upserts users from claims and derives roles", %{previous: prev} do
    configure(
      [admin_emails: ["Boss@Example.com"], admin_groups: ["platform"], groups_claim: "teams"],
      prev
    )

    assert {:ok, u} =
             Accounts.upsert_from_claims(%{
               "sub" => "s1",
               "email" => "dev@example.com",
               "name" => "Dev",
               "teams" => ["eng", :ops]
             })

    assert %{role: "viewer", groups: ["eng", "ops"], name: "Dev"} = u
    assert Accounts.get_user(u.id).email == "dev@example.com"

    assert {:ok, u2} =
             Accounts.upsert_from_claims(%{
               "sub" => "s1",
               "email" => "dev@example.com",
               "teams" => ["platform"]
             })

    assert u2.id == u.id and u2.role == "admin"

    assert {:ok, boss} =
             Accounts.upsert_from_claims(%{"sub" => "s2", "email" => "boss@example.com"})

    assert boss.role == "admin" and boss.groups == []
    assert {:ok, nosub} = Accounts.upsert_from_claims(%{"email" => "x@example.com"})
    assert nosub.subject == "x@example.com"
    assert length(Accounts.list_users()) == 3

    assert {:error, :no_email} = Accounts.upsert_from_claims(%{"sub" => "s3"})
    assert {:error, :no_email} = Accounts.upsert_from_claims(%{"sub" => "s3", "email" => ""})

    configure([allowed_email_domains: ["Example.com"]], prev)
    assert {:ok, _} = Accounts.upsert_from_claims(%{"sub" => "s4", "email" => "a@EXAMPLE.com"})

    assert {:error, :domain_not_allowed} =
             Accounts.upsert_from_claims(%{"sub" => "s5", "email" => "a@other.com"})

    assert Accounts.csv(nil) == [] and Accounts.csv(" a, ,b ") == ["a", "b"]
  end

  test "scopes in open mode depend on the admin token", %{previous: prev} do
    configure([mode: :open, admin_token: nil], prev)

    assert %Scope{mode: :open, admin?: true, admin_session?: false, user: nil} =
             Scope.from_session(%{})

    assert Scope.actor(Scope.from_session(%{})) == "anonymous"

    configure([mode: :open, admin_token: "t"], prev)
    assert %Scope{admin?: false} = Scope.from_session(%{})

    assert %Scope{admin?: true, admin_session?: true} =
             scope = Scope.from_session(%{"admin" => true})

    assert Scope.actor(scope) == "admin-token"
    configure([mode: :open, admin_token: ""], prev)
    assert %Scope{admin?: true} = Scope.from_session(%{})
  end

  test "scopes in oidc mode load the user and filter projects", %{previous: prev} do
    configure([mode: :oidc, admin_emails: ["admin@example.com"]], prev)

    {:ok, viewer} =
      Accounts.upsert_from_claims(%{
        "sub" => "v",
        "email" => "v@example.com",
        "groups" => ["team-a"]
      })

    {:ok, admin} = Accounts.upsert_from_claims(%{"sub" => "a", "email" => "admin@example.com"})

    assert %Scope{mode: :oidc, user: nil, admin?: false} = Scope.from_session(%{})
    assert %Scope{user: nil} = Scope.from_session(%{"user_id" => -1})

    assert %Scope{admin?: false, user: %{id: vid}} =
             vscope = Scope.from_session(%{"user_id" => viewer.id})

    assert vid == viewer.id
    assert Scope.actor(vscope) == "v@example.com"
    assert %Scope{admin?: true} = ascope = Scope.from_session(%{"user_id" => admin.id})

    {:ok, open} = Projects.create_project(%{slug: "open", name: "Open"})
    {:ok, a} = Projects.create_project(%{slug: "a", name: "A"})
    {:ok, a} = Projects.put_allowed_groups(a, ["team-a", " ", "team-a"])
    assert Projects.allowed_groups(a) == ["team-a"]
    {:ok, b} = Projects.create_project(%{slug: "b", name: "B"})
    {:ok, b} = Projects.put_allowed_groups(b, ["team-b"])

    assert Scope.visible_projects(vscope, [open, a, b]) == [open, a]
    assert Scope.visible_projects(ascope, [open, a, b]) == [open, a, b]
    assert Scope.visible_projects(Scope.from_session(%{}), [open, a, b]) == [open]
    assert Projects.get_project(-1) == nil
  end
end
