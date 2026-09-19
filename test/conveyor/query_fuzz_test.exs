defmodule Conveyor.QueryFuzzTest do
  use Conveyor.DataCase, async: true

  alias Conveyor.{Invocations, Query}

  @alphabet [
    "a",
    "b",
    "Z",
    "0",
    "9",
    "_",
    ".",
    "-",
    ":",
    "!",
    "=",
    "<",
    ">",
    "~",
    "*",
    "(",
    ")",
    ",",
    "\"",
    "'",
    "\\",
    " ",
    "\t",
    "user",
    "status",
    "started",
    "duration",
    "-7d",
    "5m",
    "2026-09-18",
    "//app:x",
    "é"
  ]

  # Random queries must parse to a result or an error, never raise, and every accepted
  # query must compile and run against the database (a bad regex or list must not 500).
  test "random queries never raise, and accepted ones run against the database" do
    :rand.seed(:exsss, {2026, 9, 19})

    for _ <- 1..400 do
      q =
        1..:rand.uniform(12)
        |> Enum.map_join(fn _ -> Enum.random(@alphabet) end)

      case Query.parse(q) do
        {:ok, ast} ->
          assert is_list(Invocations.list(query: ast, limit: 1)),
                 "query #{inspect(q)} failed to run"

          rendered = Query.to_query_string(ast)

          case Query.parse(rendered) do
            {:ok, ^ast} ->
              :ok

            other ->
              flunk(
                "#{inspect(q)} -> #{inspect(ast)} -> #{inspect(rendered)} -> #{inspect(other)}"
              )
          end

        {:error, message} ->
          assert is_binary(message)
      end
    end
  end
end
