defmodule Conveyor.Ingest.TagsTest do
  use ExUnit.Case, async: true

  alias Conveyor.Ingest.Tags

  test "later sources win, keys are lowercased, reserved keys are namespaced, noise is dropped" do
    merged =
      Tags.merge(%{
        derived: %{"command" => "build", "user" => "alice"},
        workspace_status: %{
          "BUILD_USER" => "bob",
          "BUILD_TIMESTAMP" => "123",
          "BUILD_EMBED_LABEL" => "",
          "STABLE_GIT_BRANCH" => "main"
        },
        keywords:
          Tags.from_keywords([
            "user_keyword=Team=infra",
            "user_keyword=nightly",
            "user_keyword=ci",
            "status=hacked"
          ]),
        api_key: %{"ci" => "false", "id" => "x"},
        metadata: %{"CI" => "true", "USER" => "alice", "" => "dropped", "empty" => ""}
      })

    assert merged == %{
             "command" => "build",
             "user" => "alice",
             "build_user" => "bob",
             "stable_git_branch" => "main",
             "team" => "infra",
             "keyword" => "nightly,ci",
             "user.status" => "hacked",
             "ci" => "true",
             "user.id" => "x"
           }
  end

  test "non-string keys and values are stringified" do
    assert Tags.merge(%{metadata: %{shard: 3}}) == %{"shard" => "3"}
    assert Tags.sources() == [:derived, :workspace_status, :keywords, :api_key, :metadata]
  end
end
