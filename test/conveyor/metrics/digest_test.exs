defmodule Conveyor.Metrics.DigestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Conveyor.Metrics.Digest

  # PostgreSQL's percentile_cont: linear interpolation at rank q × (n − 1).
  defp percentile_cont(values, q) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = q * (n - 1)
    lo = trunc(rank)
    hi = min(lo + 1, n - 1)
    Enum.at(sorted, lo) + (Enum.at(sorted, hi) - Enum.at(sorted, lo)) * (rank - lo)
  end

  test "small digests reproduce percentile_cont exactly, through JSON and merges" do
    d = Digest.new([100, 200, 300, 400, 1000, nil])
    assert d.count == 5
    assert Digest.quantile(d, 0.5) == 300.0
    assert Digest.quantile(d, 0.9) == 760.0
    assert Digest.quantile(d, 0.99) == 976.0
    assert Digest.quantile(Digest.new([]), 0.5) == nil
    assert Digest.quantile(Digest.new([7]), 0.99) == 7.0

    roundtrip = d |> Digest.to_map() |> Digest.from_map()
    assert Digest.quantile(roundtrip, 0.9) == 760.0
    assert Digest.from_map(nil).count == 0

    merged = Digest.merge(Digest.new([100, 200]), Digest.new([300, 400, 1000]))
    assert Digest.quantile(merged, 0.5) == 300.0
    assert Digest.quantile(merged, 0.99) == 976.0
  end

  property "quantiles of unit-weight digests match percentile_cont for any list" do
    check all(
            values <- list_of(integer(0..100_000), min_length: 1, max_length: 200),
            q <- float(min: 0.0, max: 1.0)
          ) do
      assert_in_delta Digest.quantile(Digest.new(values), q), percentile_cont(values, q), 1.0e-6
    end
  end

  test "large digests stay bounded and keep the tails close" do
    values = for i <- 1..20_000, do: :rand.uniform(1_000_000) + i
    d = values |> Enum.chunk_every(500) |> Enum.map(&Digest.new/1) |> Enum.reduce(&Digest.merge/2)
    assert d.count == 20_000
    assert length(d.centroids) < 400

    for q <- [0.5, 0.9, 0.99] do
      exact = percentile_cont(values, q)
      assert_in_delta Digest.quantile(d, q), exact, exact * 0.03
    end
  end
end
