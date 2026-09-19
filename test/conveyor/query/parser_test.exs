defmodule Conveyor.Query.ParserTest do
  use ExUnit.Case, async: true

  alias Conveyor.Query.Parser

  test "parses keys, operators, negation, lists, quotes and free text" do
    assert {:ok, terms} =
             Parser.parse(
               ~S|user:alice -status:succeeded duration>5m ci!=true branch~^rel key:* team:(a,b) "//app/..." path:"a b" tag:"x\"y"|
             )

    assert terms == [
             %{neg: false, key: "user", op: :eq, value: "alice"},
             %{neg: true, key: "status", op: :eq, value: "succeeded"},
             %{neg: false, key: "duration", op: :gt, value: "5m"},
             %{neg: false, key: "ci", op: :neq, value: "true"},
             %{neg: false, key: "branch", op: :regex, value: "^rel"},
             %{neg: false, key: "key", op: :exists, value: nil},
             %{neg: false, key: "team", op: :in, value: ["a", "b"]},
             %{neg: false, key: nil, op: :text, value: "//app/..."},
             %{neg: false, key: "path", op: :eq, value: "a b"},
             %{neg: false, key: "tag", op: :eq, value: ~s(x"y)}
           ]

    assert {:ok, [%{op: :gte}, %{op: :lte}, %{op: :lt}, %{op: :eq}]} =
             Parser.parse("a>=1 b<=2 c<3 d=4")

    assert {:ok, [%{neg: true, op: :in, value: ["x", "y"]}]} = Parser.parse("k!=(x,y)")
    assert {:ok, []} = Parser.parse(nil)
    assert {:ok, []} = Parser.parse("   ")
  end

  test "odd input becomes free text or an error" do
    assert {:ok, [%{key: nil, value: "-"}]} = Parser.parse("-")
    assert {:ok, [%{key: nil, value: ":x"}]} = Parser.parse(":x")
    assert {:ok, [%{key: nil, value: "a b:c"}]} = Parser.parse(~s("a b:c"))
    assert {:ok, [%{key: nil, value: "we/ird:x"}]} = Parser.parse("we/ird:x")
    assert {:error, "missing value"} = Parser.parse("user:")
    assert {:error, "unterminated quote"} = Parser.parse(~s("open))
    assert {:error, "unterminated list"} = Parser.parse("k:(a,b")
    assert {:error, "empty list"} = Parser.parse("k:()")
    assert {:error, _} = Parser.parse("k>(1,2)")
  end

  test "round-trips through to_query_string" do
    for q <- [
          "user:alice -status:failed",
          "duration>5m",
          "k:*",
          "team:(a,b)",
          "k!=(a,b)",
          ~s(path:"a b"),
          "x~^y$",
          "free",
          ~s("two words")
        ] do
      {:ok, terms} = Parser.parse(q)
      assert Parser.to_query_string(terms) == q
      assert {:ok, ^terms} = Parser.parse(Parser.to_query_string(terms))
    end
  end
end
