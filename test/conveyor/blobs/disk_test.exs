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

    assert Disk.path(@digest, Keyword.put(opts, :project_prefix, "mobile")) ==
             Path.join([opts[:dir], "mobile", "ab", "ab", @digest])

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

  # The sync calls a put makes, observed from outside the process that makes them.
  defp sync_calls(fun) do
    :erlang.trace_pattern({:prim_file, :sync, 1}, true, [:local])
    task = Task.async(fn -> receive(do: (:go -> fun.())) end)
    :erlang.trace(task.pid, true, [:call])
    send(task.pid, :go)
    result = Task.await(task)
    :erlang.trace_pattern({:prim_file, :sync, 1}, false, [:local])
    {result, collect_syncs(0)}
  end

  defp collect_syncs(n) do
    receive do
      {:trace, _pid, :call, {:prim_file, :sync, [_]}} -> collect_syncs(n + 1)
    after
      50 -> n
    end
  end

  describe "keyed objects" do
    test "a put is durable before it returns: synced file, renamed into place, synced directory",
         %{opts: opts} do
      # The object's directory is new: its ancestors up to the store's root are synced too.
      assert {:ok, syncs} =
               sync_calls(fn -> Disk.put_object("rawlog/n/0/first", "first", opts) end)

      assert syncs >= 3

      # The usual put, into a directory that exists: the file and its directory.
      assert {:ok, 2} =
               sync_calls(fn ->
                 Disk.put_object("rawlog/n/0/second", ["whole ", "object"], opts)
               end)

      assert {:ok, "whole object"} = Disk.get_range("rawlog/n/0/second", 0, 12, opts)
      # Nothing but the two objects is left under their directory.
      assert Enum.sort(File.ls!(Path.join(opts[:dir], "rawlog/n/0"))) == ["first", "second"]
    end

    test "fsync: false skips the syncs and keeps the rename", %{opts: opts} do
      opts = [fsync: false] ++ opts

      assert {:ok, 0} =
               sync_calls(fn -> Disk.put_object("rawlog/n/1/unsynced", "bytes", opts) end)

      assert {:ok, "bytes"} = Disk.get_range("rawlog/n/1/unsynced", 0, 5, opts)
      assert File.ls!(Path.join(opts[:dir], "rawlog/n/1")) == ["unsynced"]
    end

    test "a put that cannot be written is an error, and leaves nothing behind", %{opts: opts} do
      # The object's own name is taken by a directory: the rename fails, the temporary
      # file is removed.
      File.mkdir_p!(Path.join(opts[:dir], "rawlog/n/2/taken"))
      assert {:error, _} = Disk.put_object("rawlog/n/2/taken", "bytes", opts)
      assert File.ls!(Path.join(opts[:dir], "rawlog/n/2")) == ["taken"]
      # Reading or unlinking a directory is an error too, not a missing object.
      assert {:error, reason} = Disk.get_range("rawlog/n/2/taken", 0, 1, opts)
      assert reason != :not_found
      assert {[], [{"rawlog/n/2/taken", _}]} = Disk.delete_objects(["rawlog/n/2/taken"], opts)

      # The directory cannot be made: the store's root is a file.
      File.rm_rf!(opts[:dir])
      File.write!(opts[:dir], "in the way")
      assert {:error, _} = Disk.put_object("rawlog/n/3/blocked", "bytes", opts)
    end

    test "a key cannot leave the store", %{opts: opts} do
      assert_raise ArgumentError, fn -> Disk.put_object("../outside", "bytes", opts) end
      assert_raise ArgumentError, fn -> Disk.get_range("rawlog/../../outside", 0, 1, opts) end
    end
  end
end
