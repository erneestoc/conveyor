defmodule Conveyor.Metrics.Digest do
  @moduledoc """
  A mergeable quantile digest for build durations (a t-digest with Dunning's `k1` scale
  function). An hour of one project rarely holds more centroids than the compression
  allows, so its digest keeps every duration and quantiles are exact; a window of many
  hours merges the digests and compresses, keeping the tails precise.

  With unit weights only, `quantile/2` follows PostgreSQL's `percentile_cont` (linear
  interpolation between sorted values at rank `q × (n − 1)`), so the rolled-up path and the
  exact path agree to the millisecond on small sets, which the golden test asserts.
  """

  @compression 100

  @type centroid :: {float(), pos_integer()}
  @type t :: %__MODULE__{centroids: [centroid()], count: non_neg_integer()}

  defstruct centroids: [], count: 0

  @spec new([number()]) :: t()
  def new(values \\ []),
    do: values |> Enum.reject(&is_nil/1) |> Enum.reduce(%__MODULE__{}, &add(&2, &1))

  @spec add(t(), number()) :: t()
  def add(%__MODULE__{} = d, value) do
    d = %{d | centroids: [{value * 1.0, 1} | d.centroids], count: d.count + 1}
    if length(d.centroids) > 4 * @compression, do: compress(d), else: d
  end

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    compress(%__MODULE__{centroids: a.centroids ++ b.centroids, count: a.count + b.count})
  end

  @doc "Quantile `q` in `0..1`, or nil for an empty digest."
  @spec quantile(t(), float()) :: float() | nil
  def quantile(%__MODULE__{count: 0}, _q), do: nil

  def quantile(%__MODULE__{} = d, q) do
    centroids = sorted(d.centroids)
    # Position of every centroid's middle on the 0..count-1 axis; a unit-weight centroid
    # sits exactly at its rank, which is percentile_cont's convention.
    {points, _} =
      Enum.map_reduce(centroids, 0, fn {mean, w}, cum -> {{cum + (w - 1) / 2, mean}, cum + w} end)

    rank = q * (d.count - 1)
    interpolate(points, rank)
  end

  defp interpolate([{_, mean}], _rank), do: mean

  defp interpolate([{p0, m0}, {p1, m1} | rest], rank) do
    cond do
      rank <= p0 -> m0
      rank <= p1 -> m0 + (m1 - m0) * (rank - p0) / max(p1 - p0, 1.0e-9)
      rest == [] -> m1
      true -> interpolate([{p1, m1} | rest], rank)
    end
  end

  @doc "Compresses to at most about `compression` centroids, merging neighbours by the k1 bound."
  @spec compress(t()) :: t()
  def compress(%__MODULE__{count: 0} = d), do: d

  def compress(%__MODULE__{} = d) do
    n = d.count

    # Walk the sorted centroids keeping one open centroid {mean, weight} with `before`
    # points to its left; a neighbour joins it while the k-size of the merged span is ≤ 1.
    {open, before, done} =
      d.centroids
      |> sorted()
      |> Enum.reduce({nil, 0, []}, fn
        {mean, w}, {nil, before, done} ->
          {{mean, w}, before, done}

        {mean, w}, {{m, cw}, before, done} ->
          q0 = before / n
          q2 = (before + cw + w) / n

          if k(q2) - k(q0) <= 1,
            do: {{(m * cw + mean * w) / (cw + w), cw + w}, before, done},
            else: {{mean, w}, before + cw, [{m, cw} | done]}
      end)

    _ = before
    %{d | centroids: Enum.reverse([open | done])}
  end

  # Dunning's k1 scale: fine near the tails, coarse in the middle.
  defp k(q) when q <= 0, do: -@compression / 4
  defp k(q) when q >= 1, do: @compression / 4
  defp k(q), do: @compression / (2 * :math.pi()) * :math.asin(2 * q - 1)

  defp sorted(centroids), do: Enum.sort_by(centroids, &elem(&1, 0))

  @doc "JSON form (a list of `[mean, weight]`), for the rollup rows."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d),
    do: %{"c" => Enum.map(sorted(d.centroids), fn {m, w} -> [m, w] end), "n" => d.count}

  @spec from_map(map() | nil) :: t()
  def from_map(%{"c" => list, "n" => n}),
    do: %__MODULE__{centroids: Enum.map(list, fn [m, w] -> {m * 1.0, w} end), count: n}

  def from_map(_), do: %__MODULE__{}
end
