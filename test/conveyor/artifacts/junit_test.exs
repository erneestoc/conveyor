defmodule Conveyor.Artifacts.JunitTest do
  use ExUnit.Case, async: true

  alias Conveyor.Artifacts.Junit

  @fixture Path.join([
             File.cwd!(),
             "test/fixtures/blobs",
             "94a90e1beb50bfb773239210a2b21dfc0b3fbb709b3fce460f1886fc891868bc"
           ])

  test "parses Bazel's test.xml" do
    assert {:ok, [suite]} = Junit.parse(File.read!(@fixture))
    assert %{name: "app/pass_test", tests: 1, failures: 0, errors: 0, skipped: 0} = suite
    assert [%{name: "app/pass_test", status: :passed, time_ms: 0, message: nil}] = suite.cases
    assert suite.system_out =~ "pass_test: ok"
  end

  test "parses failures, errors, skips and nested suites" do
    xml = """
    <?xml version="1.0"?>
    <testsuites>
      <testsuite name="a" tests="4" failures="1" errors="1" skipped="1" time="1.5">
        <testcase name="ok" classname="pkg.A" time="0.25"/>
        <testcase name="bad" classname="pkg.A" time="0.5"><failure message="expected 1 got 2">stack trace here</failure></testcase>
        <testcase name="boom" classname="pkg.B"><error>NullPointerException
        at Foo.bar</error></testcase>
        <testcase name="later"><skipped/></testcase>
        <system-out>ignored: not directly under a suite? no, it is</system-out>
      </testsuite>
      <testsuite name="b" tests="x"></testsuite>
    </testsuites>
    """

    assert {:ok, [a, b]} = Junit.parse(xml)
    assert %{tests: 4, failures: 1, errors: 1, skipped: 1, time_ms: 1500} = a

    assert [
             %{name: "ok", classname: "pkg.A", status: :passed, time_ms: 250},
             %{name: "bad", status: :failed, message: "expected 1 got 2", time_ms: 500},
             %{name: "boom", status: :error, message: "NullPointerException\n    at Foo.bar"},
             %{name: "later", status: :skipped, message: nil, time_ms: nil}
           ] = a.cases

    assert a.system_out =~ "it is"
    assert %{name: "b", tests: 0, cases: [], system_out: nil, time_ms: nil} = b
  end

  test "rejects malformed input and ignores external entities" do
    assert {:error, "malformed XML: " <> _} = Junit.parse("<testsuite><testcase></testsuite>")
    assert {:error, _} = Junit.parse("not xml at all")

    evil = """
    <?xml version="1.0"?>
    <!DOCTYPE t [<!ENTITY secret SYSTEM "file:///etc/hostname">]>
    <testsuite name="&secret;" tests="1"><testcase name="x"/></testsuite>
    """

    case Junit.parse(evil) do
      {:ok, [suite]} -> assert suite.name in ["", "&secret;"]
      {:error, _} -> :ok
    end
  end
end
