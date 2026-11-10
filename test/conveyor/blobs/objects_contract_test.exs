defmodule Conveyor.Blobs.ObjectsContractTest do
  @moduledoc """
  The keyed-object half of `Conveyor.Blobs.Adapter` (what the raw log is built on), run
  against every adapter the gate can reach: the disk adapter, the two test doubles over
  it, and the S3 adapter against the in-process S3 server. The same assertions run
  against a real S3-compatible store in `s3_contract_test.exs` (`mix test --only s3`).
  """
  use ExUnit.Case, async: false

  alias Conveyor.Blobs.{Disk, Flaky, OneShot, S3}

  @creds [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  ]

  defp adapter(S3) do
    {port, _store} = Conveyor.FakeS3.start(@creds)
    {S3, @creds ++ [bucket: "conveyor", endpoint: "http://127.0.0.1:#{port}", path_style: true]}
  end

  defp adapter(module) do
    dir = Path.join(System.tmp_dir!(), "conveyor-objects-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {module, [dir: dir]}
  end

  @doc "The contract itself, shared with the on-demand S3 test."
  def assert_contract(adapter, opts) do
    key = "rawlog/contract/0/#{System.unique_integer([:positive])}"
    body = :crypto.strong_rand_bytes(100_000)

    assert {:error, :not_found} = adapter.get_range(key, 0, 10, opts)

    assert :ok =
             adapter.put_object(
               key,
               [binary_part(body, 0, 10), binary_part(body, 10, 99_990)],
               opts
             )

    assert {:ok, ^body} = adapter.get_range(key, 0, byte_size(body), opts)
    assert {:ok, part} = adapter.get_range(key, 40_000, 20_000, opts)
    assert part == binary_part(body, 40_000, 20_000)
    assert {:ok, <<last>>} = adapter.get_range(key, byte_size(body) - 1, 1, opts)
    assert last == :binary.last(body)

    # A range that runs past the end, or starts there, is a short read: never fewer
    # bytes than asked for.
    assert {:error, :short_read} = adapter.get_range(key, byte_size(body) - 1000, 5000, opts)
    assert {:error, :short_read} = adapter.get_range(key, byte_size(body) + 10, 1, opts)

    # The same bytes under the same key again: allowed, nothing changes.
    assert :ok = adapter.put_object(key, body, opts)
    assert {:ok, ^part} = adapter.get_range(key, 40_000, 20_000, opts)

    # Bulk delete: present and absent keys are both gone afterwards.
    others = for i <- 1..3, do: "#{key}-#{i}"
    Enum.each(others, &(:ok = adapter.put_object(&1, "x", opts)))
    absent = key <> "-absent"
    assert {deleted, []} = adapter.delete_objects([key, absent | others], opts)
    assert Enum.sort(deleted) == Enum.sort([key, absent | others])
    assert {:error, :not_found} = adapter.get_range(key, 0, 1, opts)
    assert {:error, :not_found} = adapter.get_range(hd(others), 0, 1, opts)
    assert {[^key], []} = adapter.delete_objects([key], opts)
    assert {[], []} = adapter.delete_objects([], opts)
  end

  for module <- [Disk, Flaky, OneShot, S3] do
    test "#{inspect(module)}: put whole, read by range, short reads, bulk delete" do
      {adapter, opts} = adapter(unquote(module))
      assert_contract(adapter, opts)
    end
  end

  test "Flaky fails keyed puts, ranged reads and deletes while its switches are on" do
    {Flaky, opts} = adapter(Flaky)
    switches = [:flaky_object_puts, :flaky_object_reads, :flaky_object_deletes]
    on_exit(fn -> Enum.each(switches, &Application.delete_env(:conveyor, &1)) end)
    assert :ok = Flaky.put_object("rawlog/f/0/a", "bytes", opts)

    Application.put_env(:conveyor, :flaky_object_puts, true)
    assert {:error, :store_unavailable} = Flaky.put_object("rawlog/f/0/b", "bytes", opts)
    assert {:ok, "bytes"} = Flaky.get_range("rawlog/f/0/a", 0, 5, opts)

    Application.put_env(:conveyor, :flaky_object_reads, true)
    assert {:error, :store_unavailable} = Flaky.get_range("rawlog/f/0/a", 0, 5, opts)

    Application.put_env(:conveyor, :flaky_object_deletes, true)

    assert {[], [{"rawlog/f/0/a", :store_unavailable}]} =
             Flaky.delete_objects(["rawlog/f/0/a"], opts)

    Enum.each(switches, &Application.delete_env(:conveyor, &1))
    assert {:ok, "bytes"} = Flaky.get_range("rawlog/f/0/a", 0, 5, opts)
    assert {:error, :not_found} = Flaky.get_range("rawlog/f/0/b", 0, 5, opts)
    assert {["rawlog/f/0/a"], []} = Flaky.delete_objects(["rawlog/f/0/a"], opts)
  end

  test "a failed call is counted per operation; a missing object is not a failure" do
    test = self()
    handler = "objects-errors-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:conveyor, :blobs, :errors],
      fn _, %{count: 1}, %{op: op}, _ -> send(test, {:blob_error, op}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    alias Conveyor.Blobs.Adapter

    assert {:error, :eacces} = Adapter.counted(:put_object, {:error, :eacces})
    assert_received {:blob_error, :put_object}
    assert {:error, :not_found} = Adapter.counted(:get_range, {:error, :not_found})
    assert :ok = Adapter.counted(:put_object, :ok)
    refute_received {:blob_error, _}
  end
end
