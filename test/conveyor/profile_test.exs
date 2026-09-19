defmodule Conveyor.ProfileTest do
  use ExUnit.Case, async: true

  alias Conveyor.Profile

  @fixture Path.join([
             File.cwd!(),
             "test/fixtures/blobs",
             "c9fb9e145e0fbb8955f0a0f93e7cfa750e3ab9e6e15387e5caacf811cfa7ec86"
           ])

  test "streams events out of a gzipped profile regardless of chunking" do
    gz = File.read!(@fixture)
    expected = gz |> :zlib.gunzip() |> Jason.decode!() |> Map.fetch!("traceEvents")

    for size <- [1, 7, 1000, byte_size(gz)] do
      chunks = for <<c::binary-size(^size) <- gz>>, do: c
      rest = binary_part(gz, byte_size(gz) - rem(byte_size(gz), size), rem(byte_size(gz), size))
      chunks = if rest == "", do: chunks, else: chunks ++ [rest]
      assert Profile.events(chunks) |> Enum.to_list() == expected
    end
  end

  test "handles plain JSON, strings with braces and escapes, and trailing data" do
    json =
      ~s({"otherData":{"x":"{not [an array"},"traceEvents":[{"name":"a}\\"b","ph":"X","ts":1,"dur":2,"args":{"o":{"p":"]"}}},\n {"name":"c","ph":"i","ts":3}],"tail":[{"ignored":true}]})

    assert [%{"name" => "a}\"b", "args" => %{"o" => %{"p" => "]"}}}, %{"name" => "c"}] =
             Profile.events([json]) |> Enum.to_list()

    assert Profile.events(["{\"trace", "Events\"", ": [", "{\"a\":1}", ",{\"b\":2}]"])
           |> Enum.to_list() == [%{"a" => 1}, %{"b" => 2}]

    assert Profile.events(["{\"nothing\": 1}"]) |> Enum.to_list() == []
    assert Profile.events([]) |> Enum.to_list() == []
  end

  test "summarizes the fixture profile" do
    summary = [File.read!(@fixture)] |> Profile.events() |> Profile.summarize()

    assert summary["event_count"] == 1297
    assert summary["thread_count"] > 100
    assert summary["duration_ms"] > 1000
    assert %{"name" => "Launch Blaze", "duration_ms" => 788.0} = hd(summary["phases"])

    assert Enum.any?(
             summary["phases"],
             &(&1["name"] == "Evaluate target patterns" and &1["duration_ms"] > 0)
           )

    assert [%{"name" => _, "total_ms" => _, "count" => _} | _] = summary["categories"]
    assert summary["categories"] == Enum.sort_by(summary["categories"], & &1["total_ms"], :desc)
    assert Enum.any?(summary["mnemonics"], &(&1["name"] == "Genrule"))

    assert [%{"name" => "action 'Executing genrule //lib:greeting'", "duration_ms" => 1060.3}] =
             summary["critical_path"]

    assert summary["critical_path_ms"] == 1060.3
    assert length(summary["longest"]) == 50
    assert hd(summary["longest"])["duration_ms"] >= Enum.at(summary["longest"], 1)["duration_ms"]
    assert Map.has_key?(summary["counters"], "action count")
    assert Jason.encode!(summary)
  end

  test "attributes action time to phases" do
    x = fn cat, name, ts, dur ->
      %{
        "ph" => "X",
        "pid" => 1,
        "tid" => 1,
        "cat" => cat,
        "name" => name,
        "ts" => ts,
        "dur" => dur
      }
    end

    summary =
      Profile.summarize([
        x.("action processing", "Compiling a.cc", 0, 1000),
        x.("remote action cache check", "check cache hit", 0, 100),
        x.("Remote execution upload time", "upload missing inputs", 100, 200),
        x.("remote action execution", "execute remotely", 300, 500),
        x.("remote output download", "download outputs", 800, 100),
        x.("local action execution", "subprocess.run", 2000, 50),
        x.("general information", "unrelated", 3000, 10)
      ])

    assert Enum.map(summary["action_phases"], &{&1["name"], &1["total_ms"], &1["count"]}) == [
             {"remote execution", 0.5, 1},
             {"upload inputs", 0.2, 1},
             {"cache check", 0.1, 1},
             {"download outputs", 0.1, 1},
             {"local execution", 0.1, 1}
           ]

    assert Profile.phase("Staging local action file system", "x") == "setup"
    assert Profile.phase("complete action execution", "actuallyCompleteAction") == "outputs"
    assert Profile.phase("Remote execution queuing time", "queued") == "queued"
    assert Profile.phase("general information", "x") == nil
  end

  test "summarizes synthetic events, keeping only the longest and peak counters" do
    events =
      [
        %{
          "ph" => "M",
          "name" => "thread_name",
          "pid" => 1,
          "tid" => 7,
          "args" => %{"name" => "worker"}
        }
      ] ++
        for i <- 1..500 do
          %{
            "ph" => "X",
            "cat" => "action processing",
            "name" => "e#{i}",
            "ts" => i * 10,
            "dur" => i,
            "pid" => 1,
            "tid" => 7,
            "args" => %{"mnemonic" => "Javac", "target" => "//t"}
          }
        end ++
        [
          %{"ph" => "C", "name" => "cpu", "ts" => 1, "args" => %{"user" => 1.5, "sys" => "x"}},
          %{"ph" => "C", "name" => "cpu", "ts" => 2, "args" => %{"user" => 0.5, "sys" => 3}},
          %{"ph" => "i", "cat" => "build phase marker", "name" => "start", "ts" => 0},
          %{"ph" => "i", "cat" => "build phase marker", "name" => "end", "ts" => 4000},
          %{
            "ph" => "X",
            "cat" => "critical path component",
            "name" => "c",
            "ts" => 5,
            "dur" => 5,
            "pid" => 1,
            "tid" => 0
          },
          %{"ph" => "B", "name" => "ignored"}
        ]

    summary = Profile.summarize(events)
    assert summary["event_count"] == 501
    assert summary["thread_count"] == 1

    assert [%{"name" => "start", "duration_ms" => 4.0}, %{"name" => "end", "duration_ms" => 1.5}] =
             summary["phases"]

    assert [
             %{"name" => "action processing", "count" => 500},
             %{"name" => "critical path component"}
           ] = summary["categories"]

    assert [%{"name" => "Javac", "count" => 500}] = summary["mnemonics"]

    assert [
             %{"name" => "e500", "thread" => "worker", "target" => "//t", "mnemonic" => "Javac"}
             | _
           ] = summary["longest"]

    assert length(summary["longest"]) == 50
    assert summary["counters"] == %{"cpu" => %{"user" => 1.5, "sys" => 3}}
    assert Profile.summarize([]) == Profile.summarize([%{"ph" => "M", "name" => "process_name"}])
  end
end
