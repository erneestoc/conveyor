defmodule Conveyor.Ingest.TagCounterTest do
  use Conveyor.DataCase, async: false

  import Ecto.Query

  alias Conveyor.Ingest.TagCounter
  alias Conveyor.Invocations.TagKey
  alias Conveyor.Projects
  alias Conveyor.Repo

  setup do
    %{project: Projects.ensure_default_project!()}
  end

  defp counts(key) do
    Repo.all(from t in TagKey, where: t.key == ^key, select: {t.value, t.count})
    |> Enum.sort()
  end

  test "coalesces counts into one upsert and increments existing rows", %{project: p} do
    TagCounter.add(%{{p.id, "team", "infra"} => 1, {p.id, "team", "web"} => 2})
    TagCounter.add(%{{p.id, "team", "infra"} => 3})
    assert counts("team") == []

    assert :ok = TagCounter.flush()
    assert counts("team") == [{"infra", 4}, {"web", 2}]
    assert [%{last_seen_at: %DateTime{}} | _] = Repo.all(from t in TagKey, where: t.key == "team")

    TagCounter.add(%{{p.id, "team", "web"} => 1})
    TagCounter.flush()
    assert counts("team") == [{"infra", 4}, {"web", 3}]
    assert TagCounter.add(%{}) == :ok
  end

  test "writes on its own timer and on shutdown", %{project: p} do
    {:ok, pid} = TagCounter.start_link(name: :tag_counter_timer, flush_ms: 20)
    TagCounter.add(pid, %{{p.id, "timer", "a"} => 1})
    Process.sleep(100)
    assert counts("timer") == [{"a", 1}]

    TagCounter.add(pid, %{{p.id, "timer", "b"} => 1})
    GenServer.stop(pid)
    assert counts("timer") == [{"a", 1}, {"b", 1}]
  end

  @tag :capture_log
  test "a failed flush is logged and dropped" do
    # Drain counts left by other tests' ingests so the failing statement is ours alone.
    TagCounter.flush()
    TagCounter.add(%{{nil, "bad", "v"} => 1})

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = TagCounter.flush() end)
    assert log =~ "tag counts not updated for 1 rows"
    assert log =~ "not_null_violation"
    assert counts("bad") == []
  end
end
