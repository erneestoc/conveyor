defmodule Conveyor.ExecLogTest do
  use Conveyor.DataCase, async: false
  use Oban.Testing, repo: Conveyor.Repo

  alias Conveyor.{Artifacts, Blobs, ExecLog, Projects, Repo}
  alias Conveyor.ExecLog.Spawn
  alias Conveyor.Invocations.Invocation
  alias Conveyor.Workers.ParseExecLog

  @clean Path.join([File.cwd!(), "test/fixtures/execlog/clean.log.zst"])
  @changed Path.join([File.cwd!(), "test/fixtures/execlog/changed.log.zst"])

  setup do
    project = Projects.ensure_default_project!()
    older = insert_invocation(project.id, -60, %{"branch" => "main"})
    newer = insert_invocation(project.id, 0, %{"branch" => "main"})
    %{project: project, older: older, newer: newer}
  end

  defp insert_invocation(project_id, offset_s, tags) do
    at = DateTime.add(DateTime.utc_now(), offset_s, :second)

    Repo.insert!(%Invocation{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      status: "succeeded",
      tags: tags,
      inserted_at: at,
      updated_at: at,
      started_at: at
    })
  end

  test "parses a clean build: every spawn with inputs, outputs, runner and timings" do
    assert {:ok, %{invocation_id: "609ead96-442e-491a-a30d-4d236ff6207a", spawns: spawns}} =
             ExecLog.parse(File.read!(@clean))

    assert length(spawns) == 12
    assert Enum.all?(spawns, &(&1.runner == "darwin-sandbox" and not &1.cache_hit))

    greeting = Enum.find(spawns, &(&1.target_label == "//lib:greeting"))
    assert greeting.mnemonic == "Genrule"
    assert greeting.primary_output =~ ~r{bin/lib/greeting.txt$}
    assert greeting.total_ms >= 1000 and greeting.exec_ms >= 1000
    assert greeting.input_files > 0 and greeting.input_bytes > 0

    assert [%{"path" => _, "digest" => <<_::binary-size(64)>>, "size" => 20}] =
             greeting.outputs["files"]

    assert String.length(greeting.inputs_digest) == 64 and
             String.length(greeting.outputs_digest) == 64

    # A test action is two spawns: the run (runfiles as inputs) and the test.xml generation.
    assert [test_spawn, xml_spawn] =
             spawns
             |> Enum.filter(&(&1.target_label == "//app:pass_test"))
             |> Enum.sort_by(& &1.input_files, :desc)

    assert test_spawn.mnemonic == "TestRunner" and test_spawn.input_files == 5
    assert xml_spawn.primary_output =~ ~r{pass_test/test.xml$} and xml_spawn.input_files == 2
    inputs = test_spawn.inputs_blob |> :zstd.decompress() |> IO.iodata_to_binary()
    assert inputs =~ "app/pass.sh\t"
    assert inputs =~ "external/bazel_tools/tools/test/test-setup.sh\t"
    assert inputs =~ "pass_test.runfiles/_repo_mapping\t"

    # The raw (uncompressed) form is accepted too; junk is not.
    raw = File.read!(@clean) |> :zstd.decompress() |> IO.iodata_to_binary()
    assert {:ok, %{spawns: raw_spawns}} = ExecLog.parse(raw)
    assert length(raw_spawns) == 12

    assert {:error, :not_an_execution_log} =
             ExecLog.parse(:zstd.compress("") |> IO.iodata_to_binary())

    assert {:error, :malformed} = ExecLog.parse(<<0xFF, 0xFF, 0xFF>>)
  end

  test "stores spawns, replaces them on re-parse and summarizes", %{older: inv} do
    {:ok, parsed} = ExecLog.parse(File.read!(@clean))
    assert ExecLog.store!(inv, parsed) == 12
    assert ExecLog.store!(inv, parsed) == 12
    assert length(ExecLog.list(inv)) == 12
    assert Repo.get!(Invocation, inv.id).exec_log_status == "parsed"

    assert %{spawns: 12, cache_hits: 0, executed: 12, input_bytes: bytes, output_bytes: out} =
             ExecLog.summary(inv)

    assert bytes > 0 and out > 0
    assert ExecLog.summary(Ecto.UUID.generate()) == nil

    [first | _] = ExecLog.list(inv)
    assert [{path, digest} | _] = ExecLog.inputs(first)
    assert is_binary(path) and byte_size(digest) == 64
    assert Spawn.key(first) == {first.target_label, first.mnemonic, first.primary_output}
  end

  test "explains why each spawn ran against the previous build", %{older: older, newer: newer} do
    {:ok, clean} = ExecLog.parse(File.read!(@clean))
    {:ok, changed} = ExecLog.parse(File.read!(@changed))
    ExecLog.store!(older, clean)

    # No earlier log yet: nothing to compare with.
    ExecLog.store!(newer, changed)

    assert %{previous: nil, counts: %{no_previous: 12}} = ExecLog.explain(Repo.reload!(older))

    %{previous: previous, rows: rows, counts: counts} = ExecLog.explain(Repo.reload!(newer))
    assert previous.id == older.id
    # app/pass.sh changed: pass_test and the three sharded_test shards re-ran because of it
    # (the script and the executable symlink to it). Their test.xml generation spawns re-ran
    # with identical inputs, because Bazel re-runs the whole test action.
    assert counts == %{inputs_changed: 4, same_inputs: 4}
    pass = Enum.find(rows, &(&1.spawn.target_label == "//app:pass_test" and &1.changed != []))
    assert pass.changed == ["app/pass.sh", "bazel-out/darwin_arm64-fastbuild/bin/app/pass_test"]
    assert pass.added == [] and pass.removed == [] and pass.outputs_changed? == false
    xml = Enum.find(rows, &(&1.spawn.target_label == "//app:pass_test" and &1.changed == []))
    assert xml.reason == :same_inputs and xml.spawn.primary_output =~ "test.xml"

    # Same inputs as before: re-executed anyway (cache miss or non-hermetic).
    ExecLog.store!(newer, clean)
    %{counts: counts, rows: rows} = ExecLog.explain(Repo.reload!(newer))
    assert counts == %{same_inputs: 12}
    assert Enum.all?(rows, &(&1.outputs_changed? == false))

    # A spawn the previous build never ran is new; a cache hit needs no explanation.
    extra = %{hd(clean.spawns) | target_label: "//lib:brand_new", cache_hit: false}
    hit = %{hd(clean.spawns) | target_label: "//lib:cached", cache_hit: true}
    ExecLog.store!(newer, %{spawns: [extra, hit]})
    assert %{counts: %{new: 1, cache_hit: 1}} = ExecLog.explain(Repo.reload!(newer))
  end

  test "the previous build must be on the same branch when the build has one", %{
    project: project,
    older: older,
    newer: newer
  } do
    {:ok, clean} = ExecLog.parse(File.read!(@clean))
    ExecLog.store!(older, clean)
    ExecLog.store!(newer, clean)
    assert ExecLog.previous_with_log(Repo.reload!(newer)).id == older.id

    feature = insert_invocation(project.id, 1, %{"branch" => "feature/x"})
    ExecLog.store!(feature, clean)
    assert ExecLog.previous_with_log(Repo.reload!(feature)) == nil

    untagged = insert_invocation(project.id, 2, %{})
    ExecLog.store!(untagged, clean)
    assert ExecLog.previous_with_log(Repo.reload!(untagged)).id == feature.id
  end

  test "the worker parses the uploaded artifact and reports failures", %{newer: inv} do
    {:ok, blob} = Blobs.put(inv.project_id, File.read!(@clean), content_type: "application/zstd")
    Artifacts.attach(inv, "execution.log.zst", blob, "upload")
    Phoenix.PubSub.subscribe(Conveyor.PubSub, Conveyor.Ingest.invocation_topic(inv.id))

    :ok = ExecLog.available(inv, blob)
    assert Repo.get!(Invocation, inv.id).exec_log_status == "available"
    assert_enqueued(worker: ParseExecLog, args: %{invocation_id: inv.id})
    assert {:ok, 12} = perform_job(ParseExecLog, %{invocation_id: inv.id})
    assert_receive {:artifacts_changed, _}
    assert Repo.get!(Invocation, inv.id).exec_log_status == "parsed"

    assert {:cancel, :no_invocation} =
             perform_job(ParseExecLog, %{invocation_id: Ecto.UUID.generate()})

    other =
      Repo.insert!(%Invocation{
        id: Ecto.UUID.generate(),
        project_id: inv.project_id,
        inserted_at: inv.inserted_at,
        updated_at: inv.inserted_at
      })

    assert {:cancel, :no_log} = perform_job(ParseExecLog, %{invocation_id: other.id})

    {:ok, junk} = Blobs.put(inv.project_id, "not a log", content_type: "application/octet-stream")
    Artifacts.attach(other, "exec.log", junk, "upload")
    assert {:cancel, :malformed} = perform_job(ParseExecLog, %{invocation_id: other.id})
    assert Repo.get!(Invocation, other.id).exec_log_status == "failed"
  end

  test "input-set lattices expand in linear time" do
    # A Fibonacci lattice: set n = {file n} ∪ set n-1 ∪ set n-2, so the number of paths to
    # file 1 grows exponentially with depth while the unique inputs grow linearly. This is
    # the shape of real logs (a test's runfiles reach a library's headers through every
    # dependent); on the AWS trial the list-based expansion took minutes on a 429-spawn
    # abseil log and never finished inside Oban's rescue window.
    alias Tools.Protos.ExecLogEntry, as: Entry

    depth = 80
    digest = %Tools.Protos.Digest{hash: String.duplicate("a", 64), size_bytes: 1}

    files =
      for n <- 1..depth,
          do: %Entry{id: n, type: {:file, %Entry.File{path: "src/f#{n}.h", digest: digest}}}

    sets =
      for n <- 1..depth do
        transitive = Enum.filter([n - 1, n - 2], &(&1 >= 1)) |> Enum.map(&(depth + &1))

        %Entry{
          id: depth + n,
          type: {:input_set, %Entry.InputSet{input_ids: [n], transitive_set_ids: transitive}}
        }
      end

    spawns =
      for n <- 1..depth do
        %Entry{
          id: 2 * depth + n,
          type:
            {:spawn,
             %Entry.Spawn{
               input_set_id: depth + n,
               mnemonic: "CppCompile",
               target_label: "//pkg:t#{n}",
               outputs: []
             }}
        }
      end

    entries =
      [%Entry{id: 0, type: {:invocation, %Entry.Invocation{id: "lattice"}}} | files] ++
        sets ++ spawns

    binary =
      entries
      |> Enum.map(&Entry.encode/1)
      |> Enum.map(&[Conveyor.Bep.Fixture.encode_varint(byte_size(&1)), &1])
      |> IO.iodata_to_binary()

    {us, {:ok, %{spawns: rows}}} = :timer.tc(fn -> ExecLog.parse(binary) end)
    assert div(us, 1000) < 2_000
    assert Enum.map(rows, & &1.input_files) == Enum.to_list(1..depth)
    last = List.last(rows)
    inputs = last.inputs_blob |> :zstd.decompress() |> IO.iodata_to_binary() |> String.split("\n")
    assert length(inputs) == depth and hd(inputs) == "src/f1.h\t" <> String.duplicate("a", 64)
  end

  test "artifact names that look like execution logs" do
    assert ExecLog.name?("execution.log")
    assert ExecLog.name?("execution.log.zst")
    assert ExecLog.name?("exec_log.zst")
    assert ExecLog.name?("build.execlog")
    refute ExecLog.name?("command.profile.gz")
    refute ExecLog.name?(nil)
  end
end
