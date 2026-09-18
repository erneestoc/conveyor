defmodule Conveyor.ProjectsTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.Projects
  alias Conveyor.Projects.{ApiKey, ApiKeyCache}

  setup do
    ApiKeyCache.clear()
    {:ok, project} = Projects.create_project(%{slug: "Payments", name: "Payments"})
    %{project: project}
  end

  test "projects: create, list, slug validation, archive, default", %{project: project} do
    assert project.slug == "payments"
    assert {:error, changeset} = Projects.create_project(%{slug: "Bad Slug!", name: "x"})
    assert %{slug: [_]} = errors_on(changeset)
    assert {:error, _} = Projects.create_project(%{slug: "payments", name: "dup"})
    assert Projects.get_project_by_slug("payments").id == project.id
    assert Projects.get_project!(project.id).name == "Payments"
    assert {:ok, renamed} = Projects.update_project(project, %{name: "Pay"})
    assert renamed.name == "Pay"

    default = Projects.ensure_default_project!()
    assert default.slug == "default" and Projects.ensure_default_project!().id == default.id
    assert Enum.map(Projects.list_projects(), & &1.slug) == ["default", "payments"]

    {:ok, _} = Projects.archive_project(project)
    assert Enum.map(Projects.list_projects(), & &1.slug) == ["default"]
    assert length(Projects.list_projects(include_archived: true)) == 2
  end

  test "api keys: create, verify, scopes, tags, touch, list", %{project: project} do
    assert {:ok, key, plaintext} =
             Projects.create_api_key(project, %{
               name: "ci",
               scopes: ["ingest", "read"],
               default_tags: %{"ci" => "true"}
             })

    assert plaintext =~ ~r/^conveyor_[a-z2-7]{8}_[A-Za-z0-9_-]{43}$/

    assert key.key_hash != plaintext and
             key.key_id == plaintext |> String.split("_") |> Enum.at(1)

    assert {:ok, verified} = Projects.verify_api_key(plaintext)
    assert verified.id == key.id and verified.project.id == project.id
    assert {:ok, _} = Projects.verify_api_key(plaintext), "second lookup is served from the cache"

    assert {:error, :malformed} = Projects.verify_api_key("nope")
    assert {:error, :malformed} = Projects.verify_api_key("conveyor_short_x")
    assert {:error, :malformed} = Projects.verify_api_key(nil)
    assert {:error, :unknown} = Projects.verify_api_key("conveyor_abcdefgh_secret")

    assert {:error, :unknown} =
             Projects.verify_api_key(
               String.replace_suffix(plaintext, String.last(plaintext), "!")
             )

    assert {:error, cs} = Projects.create_api_key(project, %{name: "", scopes: ["nope"]})
    assert %{name: [_], scopes: [_]} = errors_on(cs)
    assert {:error, cs} = Projects.create_api_key(project, %{name: "x", scopes: []})
    assert %{scopes: [_]} = errors_on(cs)

    assert {:error, cs} =
             Projects.create_api_key(project, %{name: "x", default_tags: %{"" => "v"}})

    assert %{default_tags: [_]} = errors_on(cs)

    assert :ok = Projects.touch_api_key(key, "10.0.0.1")
    touched = Projects.get_api_key!(key.id)
    assert touched.last_used_at != nil and touched.last_used_ip == "10.0.0.1"

    assert :ok = Projects.touch_api_key(touched, "10.0.0.2"),
           "throttled: no second write within a minute"

    assert Projects.get_api_key!(key.id).last_used_ip == "10.0.0.1"

    assert [%ApiKey{id: id}] = Projects.list_api_keys(project)
    assert id == key.id and Projects.list_api_keys(project.id) != []
    assert ApiKey.scopes() == ["ingest", "upload", "read"]
  end

  test "revocation, expiry and rotation with grace", %{project: project} do
    {:ok, key, plaintext} =
      Projects.create_api_key(project, %{name: "k", default_tags: %{"team" => "a"}})

    {:ok, successor, new_plaintext} =
      Projects.rotate_api_key(key, grace_days: 1, created_by: "admin@example.com")

    assert successor.rotated_from_id == key.id and successor.default_tags == %{"team" => "a"} and
             successor.created_by == "admin@example.com"

    assert {:ok, _} = Projects.verify_api_key(plaintext),
           "old key still works during the grace period"

    assert {:ok, _} = Projects.verify_api_key(new_plaintext)
    old = Projects.get_api_key!(key.id)
    assert DateTime.diff(old.expires_at, DateTime.utc_now(), :hour) in 23..24
    assert [%{id: expiring_id}] = Projects.expiring_api_keys(2)
    assert expiring_id == key.id
    assert Projects.expiring_api_keys(0) == []

    {:ok, _} = Projects.revoke_api_key(old)
    assert {:error, :revoked} = Projects.verify_api_key(plaintext)

    {:ok, expired, expired_plaintext} =
      Projects.create_api_key(project, %{
        name: "old",
        expires_at: DateTime.add(DateTime.utc_now(), -60)
      })

    assert {:error, :expired} = Projects.verify_api_key(expired_plaintext)
    refute ApiKey.active?(expired, DateTime.utc_now())

    # Rotating keeps the earlier of the existing and the grace expiry.
    {:ok, _, _} = Projects.rotate_api_key(expired, grace_days: 30)
    assert Projects.get_api_key!(expired.id).expires_at == expired.expires_at
  end

  test "cache entries expire and can be invalidated", %{project: project} do
    {:ok, key, plaintext} = Projects.create_api_key(project, %{name: "k"})
    assert {:ok, _} = Projects.verify_api_key(plaintext)
    assert ApiKeyCache.fetch(key.key_id, fn _ -> :loader_not_called end) != :loader_not_called
    ApiKeyCache.invalidate(key.key_id)
    Process.sleep(20)
    assert ApiKeyCache.fetch(key.key_id, fn _ -> :reloaded end) == :reloaded
    ApiKeyCache.clear()
    assert ApiKeyCache.fetch(key.key_id, fn _ -> :cleared end) == :cleared
  end
end
