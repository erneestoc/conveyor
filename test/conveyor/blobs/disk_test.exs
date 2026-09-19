defmodule Conveyor.Blobs.DiskTest do
  use ExUnit.Case, async: true

  alias Conveyor.Blobs.Disk

  @digest String.duplicate("ab", 32)

  setup do
    dir = Path.join(System.tmp_dir!(), "conveyor-disk-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, opts: [dir: dir]}
  end

  test "put, stream, exists?, delete round trip", %{opts: opts} do
    refute Disk.exists?(@digest, opts)
    assert {:error, :not_found} = Disk.stream(@digest, opts)
    assert :ok = Disk.put(@digest, ["hello ", "world"], opts)
    assert Disk.exists?(@digest, opts)
    assert Disk.path(@digest, opts) == Path.join([opts[:dir], "ab", "ab", @digest])
    assert {:ok, stream} = Disk.stream(@digest, opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "hello world"
    assert [] = Path.wildcard(Path.join(opts[:dir], "**/*.tmp-*"))
    assert :ok = Disk.delete(@digest, opts)
    assert :ok = Disk.delete(@digest, opts)
    refute Disk.exists?(@digest, opts)
  end

  test "a failing stream leaves no partial blob behind", %{opts: opts} do
    boom = Stream.map([1], fn _ -> raise "boom" end)
    assert {:error, %RuntimeError{}} = Disk.put(@digest, boom, opts)
    refute Disk.exists?(@digest, opts)

    assert [] =
             Path.wildcard(Path.join(opts[:dir], "**/*"), match_dot: true)
             |> Enum.filter(&File.regular?/1)
  end

  test "delete reports errors other than a missing file", %{opts: opts} do
    :ok = Disk.put(@digest, ["x"], opts)
    File.chmod!(Path.dirname(Disk.path(@digest, opts)), 0o500)
    on_exit(fn -> File.chmod(Path.dirname(Disk.path(@digest, opts)), 0o700) end)
    assert {:error, :eacces} = Disk.delete(@digest, opts)
  end
end
