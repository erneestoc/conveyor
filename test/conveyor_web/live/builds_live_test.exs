defmodule ConveyorWeb.BuildsLiveTest do
  use ConveyorWeb.LiveCase, async: false

  alias Conveyor.Ingest
  alias Conveyor.Projects

  setup do
    ctx = context()
    ok_id = ingest_fixture!("clean_build_and_test", ctx)
    failed_id = ingest_fixture!("test_failure", ctx)
    %{ctx: ctx, ok_id: ok_id, failed_id: failed_id}
  end

  test "lists builds newest first with status filters", %{
    conn: conn,
    ok_id: ok_id,
    failed_id: failed_id
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#inv-#{ok_id}")
    assert has_element?(view, "#inv-#{failed_id}")
    assert has_element?(view, "#inv-#{failed_id} [data-status=failed]")

    view |> element("#filter-failed") |> render_click()
    assert_patch(view, ~p"/?status=failed")
    refute has_element?(view, "#inv-#{ok_id}")
    assert has_element?(view, "#inv-#{failed_id}")

    view |> element("#filter-succeeded") |> render_click()
    assert has_element?(view, "#inv-#{ok_id}")
    refute has_element?(view, "#inv-#{failed_id}")

    view |> element("#filter-running") |> render_click()
    refute has_element?(view, "#inv-#{ok_id}")

    assert has_element?(view, "#invocations tr.only\\:table-row") or
             render(view) =~ "No builds yet"
  end

  test "scopes to a project and rejects unknown slugs", %{conn: conn, ok_id: ok_id} do
    {:ok, view, _} = live(conn, ~p"/p/default")
    assert has_element?(view, "#inv-#{ok_id}")
    assert has_element?(view, "#project-switcher")

    {:ok, other} = Projects.create_project(%{slug: "other", name: "Other"})
    {:ok, view, _} = live(conn, ~p"/p/#{other.slug}")
    refute has_element?(view, "#inv-#{ok_id}")

    assert_raise ConveyorWeb.NotFoundError, fn -> live(conn, ~p"/p/nope") end
  end

  test "inserts and updates rows from ingest digests", %{conn: conn, ctx: ctx, ok_id: ok_id} do
    {:ok, view, _} = live(conn, ~p"/?status=running")
    refute has_element?(view, "#inv-#{ok_id}")

    new_id = Conveyor.Bep.Replay.uuid()

    summary = %{
      id: new_id,
      project_id: ctx.project_id,
      status: "in_progress",
      command: "build",
      patterns: ["//..."],
      tags: %{},
      started_at: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(Conveyor.PubSub, Ingest.all_topic(), {:invocation_updated, summary})
    assert render(view) =~ new_id
    assert has_element?(view, "#inv-#{new_id} [data-status=in_progress]")

    # Finishing moves it out of the "running" filter.
    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.all_topic(),
      {:invocation_updated, %{summary | status: "succeeded"}}
    )

    refute has_element?(view, "#inv-#{new_id}")

    # An unrelated update for something not shown is ignored.
    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.all_topic(),
      {:invocation_updated, %{summary | id: Conveyor.Bep.Replay.uuid(), status: "failed"}}
    )

    refute has_element?(view, "[data-status=failed]")

    # Same row updated in place under the matching filter.
    {:ok, view, _} = live(conn, ~p"/")
    Phoenix.PubSub.broadcast(Conveyor.PubSub, Ingest.all_topic(), {:invocation_updated, summary})

    Phoenix.PubSub.broadcast(
      Conveyor.PubSub,
      Ingest.all_topic(),
      {:invocation_updated, %{summary | status: "succeeded"}}
    )

    assert has_element?(view, "#inv-#{new_id} [data-status=succeeded]")
  end

  test "loads more pages", %{conn: conn, ctx: ctx} do
    now = DateTime.utc_now()

    for i <- 1..60 do
      Conveyor.Repo.insert!(%Conveyor.Invocations.Invocation{
        id: Conveyor.Bep.Replay.uuid(),
        project_id: ctx.project_id,
        status: "succeeded",
        started_at: DateTime.add(now, -i, :second)
      })
    end

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#load-more")
    view |> element("#load-more") |> render_click()
    refute has_element?(view, "#load-more")
    assert render(view) |> String.split("data-status=") |> length() > 60
  end
end
