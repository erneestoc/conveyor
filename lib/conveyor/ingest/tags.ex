defmodule Conveyor.Ingest.Tags do
  @moduledoc """
  Builds the schema-less tag map of an invocation from its sources, later sources winning:

  1. server-derived (`command`, `bazel_version`, `host`, `user`)
  2. `WorkspaceStatus` items
  3. BES notification keywords (`user_keyword=K=V`)
  4. API key default tags
  5. `BuildMetadata` (`--build_metadata=K=V`), authoritative
  """

  @sources [:derived, :workspace_status, :keywords, :api_key, :metadata]
  @reserved ~w(status id project)
  # Volatile per-build values Bazel always emits; they would only pollute facets.
  # (build_timestamp etc. come from workspace status; command_name/protocol_name are
  # Bazel's own system keywords and duplicate the command column)
  @ignored ~w(build_timestamp formatted_date build_embed_label command_name protocol_name)

  @type sources :: %{optional(atom()) => %{String.t() => String.t()}}

  def sources, do: @sources

  @doc "Merges all sources into one normalized map (lowercase keys, string values)."
  @spec merge(sources()) :: %{String.t() => String.t()}
  def merge(sources) do
    Enum.reduce(@sources, %{}, fn source, acc ->
      sources |> Map.get(source, %{}) |> Enum.reduce(acc, fn {k, v}, acc -> put(acc, k, v) end)
    end)
  end

  @doc "Parses `--bes_keywords` notification keywords into tags; `user_keyword=k=v` becomes k → v."
  @spec from_keywords([String.t()]) :: %{String.t() => String.t()}
  def from_keywords(keywords) do
    Enum.reduce(keywords, %{}, fn keyword, acc ->
      case keyword |> String.replace_prefix("user_keyword=", "") |> String.split("=", parts: 2) do
        [k, v] -> put(acc, k, v)
        [k] -> put(acc, "keyword", Enum.join(Enum.reject([acc["keyword"], k], &is_nil/1), ","))
      end
    end)
  end

  defp put(acc, key, value) when is_binary(key) and is_binary(value) do
    key = key |> String.trim() |> String.downcase()

    cond do
      key == "" or value == "" -> acc
      key in @ignored -> acc
      key in @reserved -> Map.put(acc, "user." <> key, value)
      true -> Map.put(acc, key, value)
    end
  end

  defp put(acc, key, value), do: put(acc, to_string(key), to_string(value))
end
