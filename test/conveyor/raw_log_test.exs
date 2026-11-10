defmodule Conveyor.RawLogTest do
  use Conveyor.DataCase, async: false

  alias Conveyor.RawLog

  test "objects are registered, written, read by range and swept by age" do
    key = RawLog.new_key(3)
    assert key =~ ~r"^rawlog/[^/]+/3/[0-9a-v]{10}[a-z2-7]{8}$"
    assert :ok = RawLog.put(key, ["hello ", "raw ", "log"])
    assert {:ok, "raw"} = RawLog.get_range(key, 6, 3)
    assert {:error, :short_read} = RawLog.get_range(key, 6, 30)
    assert {:error, :enoent} = RawLog.get_range("rawlog/none/0/x", 0, 1)

    # Not old enough: nothing swept; then everything registered before "now" goes.
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), -3600, :second)) == 0
    assert {:ok, _} = RawLog.get_range(key, 0, 5)
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) == 1
    assert {:error, :enoent} = RawLog.get_range(key, 0, 1)
    assert RawLog.sweep(DateTime.add(DateTime.utc_now(), 1, :second)) == 0
    refute RawLog.blob_mode?()
    assert RawLog.flush_ms() == 1000
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

  defp root, do: Conveyor.Blobs.adapter() |> elem(1) |> Keyword.fetch!(:dir)
  defp dir_of(key), do: root() |> Path.join(key) |> Path.dirname()

  test "a disk put is durable before it returns: synced file, renamed into place, synced directory" do
    # The shard's directory is new: its ancestors up to the store's root are synced too.
    first = RawLog.new_key("durable-#{System.unique_integer([:positive])}")
    assert {:ok, syncs} = sync_calls(fn -> RawLog.put(first, "first") end)
    assert syncs >= 3

    # The usual put, into a directory that exists: the file and its directory.
    key = String.replace(first, ~r"[^/]+$", "second")
    assert {:ok, 2} = sync_calls(fn -> RawLog.put(key, ["whole ", "object"]) end)
    assert {:ok, "whole object"} = RawLog.get_range(key, 0, 12)
    # Nothing but the two objects is left under their directory.
    assert Enum.sort(File.ls!(dir_of(key))) == Enum.sort([Path.basename(first), "second"])
    assert RawLog.fsync?()
  end

  test "a disk put that cannot be written is an error, and leaves nothing behind" do
    previous = Application.get_env(:conveyor, Conveyor.Blobs)
    on_exit(fn -> Application.put_env(:conveyor, Conveyor.Blobs, previous) end)
    blocked_root = Path.join(root(), "blocked-#{System.unique_integer([:positive])}")
    File.mkdir_p!(blocked_root)
    Application.put_env(:conveyor, Conveyor.Blobs, adapter: :disk, dir: blocked_root)

    # The object's own name is taken by a directory: the rename fails, the temporary
    # file is removed.
    key = RawLog.new_key(:taken)
    File.mkdir_p!(Path.join(blocked_root, key))
    assert {:error, _} = RawLog.put(key, "bytes")
    assert File.ls!(dir_of(key)) == [Path.basename(key)]

    # The shard's directory cannot be made: the store's root is a file.
    File.rm_rf!(blocked_root)
    File.write!(blocked_root, "in the way")
    assert {:error, _} = RawLog.put(RawLog.new_key(:blocked), "bytes")
  end

  test "RAW_LOG_FSYNC=false skips the syncs and keeps the rename" do
    previous = Application.get_env(:conveyor, RawLog)
    on_exit(fn -> Application.put_env(:conveyor, RawLog, previous) end)
    Application.put_env(:conveyor, RawLog, Keyword.put(previous || [], :fsync, false))
    refute RawLog.fsync?()

    key = RawLog.new_key("nosync-#{System.unique_integer([:positive])}")
    assert {:ok, 0} = sync_calls(fn -> RawLog.put(key, "unsynced") end)
    assert {:ok, "unsynced"} = RawLog.get_range(key, 0, 8)
    assert File.ls!(dir_of(key)) == [Path.basename(key)]
  end
end
