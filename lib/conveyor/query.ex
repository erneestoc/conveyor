defmodule Conveyor.Query do
  @moduledoc """
  The build search language: parse (`Conveyor.Query.Parser`), compile to an Ecto dynamic
  (`to_dynamic/2`) and evaluate against an in-memory invocation map (`matches?/2`) so live
  updates can be filtered without a round trip. Both paths implement the same semantics.

  Built-in keys map to invocation columns; every other key is a tag lookup.
  """
  import Ecto.Query

  alias Conveyor.Query.{Parser, Values}

  @type ast :: [Parser.term_ast()]

  @columns %{
    "status" => {:status, :status},
    "command" => {:string, :command},
    "user" => {:string, :user_name},
    "host" => {:string, :host},
    "bazel" => {:string, :bazel_version},
    "exit" => {:string, :exit_code_name},
    "build" => {:string, :build_id},
    "id" => {:string, :id},
    "pattern" => {:array, :patterns},
    "duration" => {:duration, :duration_ms},
    "analysis" => {:duration, :analysis_ms},
    "execution" => {:duration, :execution_ms},
    "critical_path" => {:duration, :critical_path_ms},
    "targets" => {:integer, :targets_configured},
    "targets_failed" => {:integer, :targets_failed},
    "tests" => {:integer, :tests_total},
    "tests_failed" => {:integer, :tests_failed},
    "tests_flaky" => {:integer, :tests_flaky},
    "actions" => {:integer, :actions_executed},
    "cache_hits" => {:integer, :remote_cache_hits},
    "started" => {:datetime, :started_at},
    "finished" => {:datetime, :finished_at}
  }

  @status_aliases %{
    "running" => "in_progress",
    "success" => "succeeded",
    "ok" => "succeeded",
    "fail" => "failed",
    "error" => "failed"
  }

  @doc "Built-in keys, for autocomplete and docs."
  def builtin_keys, do: Map.keys(@columns) |> Enum.sort()

  defdelegate parse(string), to: Parser
  defdelegate to_query_string(ast), to: Parser

  @doc "Parses, returning `[]` for invalid input (callers that only need best effort)."
  def parse!(string) do
    case Parser.parse(string) do
      {:ok, ast} -> ast
      {:error, _} -> []
    end
  end

  # --- Ecto ----------------------------------------------------------------------------------------

  @doc "Compiles the AST to a dynamic expression over an `Invocation` binding named `i`."
  @spec to_dynamic(ast(), keyword()) :: Ecto.Query.dynamic_expr()
  def to_dynamic(ast, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Enum.reduce(ast, dynamic(true), fn term, acc ->
      clause = term_dynamic(term, now)
      # A negated term matches everything the term does not, including rows where the
      # value is missing (SQL NULL), which is what the in-memory evaluator does too.
      clause = if term.neg, do: dynamic([i], not coalesce(^clause, false)), else: clause
      dynamic([i], ^acc and ^clause)
    end)
  end

  defp term_dynamic(%{key: nil, value: text}, _now) do
    like = "%#{escape_like(text)}%"

    dynamic(
      [i],
      ilike(i.command, ^like) or ilike(i.user_name, ^like) or ilike(i.host, ^like) or
        fragment("array_to_string(?, ' ') ILIKE ?", i.patterns, ^like) or
        fragment("?::text ILIKE ?", i.tags, ^like)
    )
  end

  defp term_dynamic(%{key: key} = term, now) do
    case Map.fetch(@columns, key) do
      {:ok, {type, column}} -> column_dynamic(type, column, term, now)
      :error -> tag_dynamic(key, term)
    end
  end

  defp column_dynamic(:status, column, term, now),
    do: column_dynamic(:string, column, normalize_status(term), now)

  defp column_dynamic(:string, column, %{op: :exists}, _now),
    do: dynamic([i], not is_nil(field(i, ^column)))

  defp column_dynamic(:string, column, %{op: :eq, value: v}, _now),
    do: dynamic([i], fragment("lower(?::text) = ?", field(i, ^column), ^String.downcase(v)))

  defp column_dynamic(:string, column, %{op: :neq, value: v}, _now),
    do:
      dynamic(
        [i],
        is_nil(field(i, ^column)) or
          fragment("lower(?::text) <> ?", field(i, ^column), ^String.downcase(v))
      )

  defp column_dynamic(:string, column, %{op: :in, value: values}, _now),
    do:
      dynamic(
        [i],
        fragment(
          "lower(?::text) = ANY(?)",
          field(i, ^column),
          ^Enum.map(values, &String.downcase/1)
        )
      )

  defp column_dynamic(:string, column, %{op: :regex, value: v}, _now),
    do: if_regex(v, dynamic([i], fragment("?::text ~* ?", field(i, ^column), ^v)))

  defp column_dynamic(:string, _column, _term, _now), do: dynamic([i], false)

  defp column_dynamic(:array, column, %{op: :exists}, _now),
    do: dynamic([i], fragment("cardinality(?) > 0", field(i, ^column)))

  defp column_dynamic(:array, column, %{op: :eq, value: v}, _now),
    do: dynamic([i], fragment("? = ANY(?)", ^v, field(i, ^column)))

  defp column_dynamic(:array, column, %{op: :neq, value: v}, _now),
    do: dynamic([i], fragment("NOT (? = ANY(?))", ^v, field(i, ^column)))

  defp column_dynamic(:array, column, %{op: :in, value: values}, _now),
    do: dynamic([i], fragment("? && ?", field(i, ^column), ^values))

  defp column_dynamic(:array, column, %{op: :regex, value: v}, _now),
    do:
      if_regex(
        v,
        dynamic(
          [i],
          fragment("EXISTS (SELECT 1 FROM unnest(?) p WHERE p ~* ?)", field(i, ^column), ^v)
        )
      )

  defp column_dynamic(:array, _column, _term, _now), do: dynamic([i], false)

  defp column_dynamic(type, column, %{op: op, value: v}, now)
       when type in [:duration, :integer, :datetime] and op in [:eq, :neq, :gt, :gte, :lt, :lte] do
    case typed(type, v, now) do
      {:ok, value} -> compare(column, op, value)
      :error -> dynamic([i], false)
    end
  end

  defp column_dynamic(type, column, %{op: :in, value: values}, now)
       when type in [:duration, :integer, :datetime] do
    values
    |> Enum.map(&typed(type, &1, now))
    |> Enum.reduce(dynamic(false), fn
      {:ok, value}, acc -> dynamic([i], ^acc or field(i, ^column) == ^value)
      :error, acc -> acc
    end)
  end

  defp column_dynamic(type, column, %{op: :exists}, _now)
       when type in [:duration, :integer, :datetime],
       do: dynamic([i], not is_nil(field(i, ^column)))

  defp column_dynamic(_type, _column, _term, _now), do: dynamic([i], false)

  defp compare(column, :eq, value), do: dynamic([i], field(i, ^column) == ^value)

  defp compare(column, :neq, value),
    do: dynamic([i], is_nil(field(i, ^column)) or field(i, ^column) != ^value)

  defp compare(column, :gt, value), do: dynamic([i], field(i, ^column) > ^value)
  defp compare(column, :gte, value), do: dynamic([i], field(i, ^column) >= ^value)
  defp compare(column, :lt, value), do: dynamic([i], field(i, ^column) < ^value)
  defp compare(column, :lte, value), do: dynamic([i], field(i, ^column) <= ^value)

  defp tag_dynamic(key, %{op: :exists}), do: dynamic([i], fragment("? \\? ?", i.tags, ^key))

  defp tag_dynamic(key, %{op: :eq, value: v}),
    do: dynamic([i], fragment("lower(?->>?) = ?", i.tags, ^key, ^String.downcase(v)))

  defp tag_dynamic(key, %{op: :neq, value: v}),
    do:
      dynamic([i], fragment("lower(coalesce(?->>?, '')) <> ?", i.tags, ^key, ^String.downcase(v)))

  defp tag_dynamic(key, %{op: :in, value: values}),
    do:
      dynamic(
        [i],
        fragment("lower(?->>?) = ANY(?)", i.tags, ^key, ^Enum.map(values, &String.downcase/1))
      )

  defp tag_dynamic(key, %{op: :regex, value: v}),
    do: if_regex(v, dynamic([i], fragment("(?->>?) ~* ?", i.tags, ^key, ^v)))

  defp tag_dynamic(key, %{op: op, value: v}) when op in [:gt, :gte, :lt, :lte] do
    case Values.number(v) do
      {:ok, n} ->
        n = n * 1.0
        # CASE guarantees the cast only runs on numeric-looking values.
        case op do
          :gt ->
            dynamic(
              [i],
              fragment(
                "(CASE WHEN (?->>?) ~ '^-\\?[0-9]+(\\.[0-9]+)\\?$' THEN (?->>?)::float END) > ?",
                i.tags,
                ^key,
                i.tags,
                ^key,
                ^n
              )
            )

          :gte ->
            dynamic(
              [i],
              fragment(
                "(CASE WHEN (?->>?) ~ '^-\\?[0-9]+(\\.[0-9]+)\\?$' THEN (?->>?)::float END) >= ?",
                i.tags,
                ^key,
                i.tags,
                ^key,
                ^n
              )
            )

          :lt ->
            dynamic(
              [i],
              fragment(
                "(CASE WHEN (?->>?) ~ '^-\\?[0-9]+(\\.[0-9]+)\\?$' THEN (?->>?)::float END) < ?",
                i.tags,
                ^key,
                i.tags,
                ^key,
                ^n
              )
            )

          :lte ->
            dynamic(
              [i],
              fragment(
                "(CASE WHEN (?->>?) ~ '^-\\?[0-9]+(\\.[0-9]+)\\?$' THEN (?->>?)::float END) <= ?",
                i.tags,
                ^key,
                i.tags,
                ^key,
                ^n
              )
            )
        end

      :error ->
        dynamic([i], false)
    end
  end

  # An invalid pattern would make Postgres fail the whole query; match nothing instead.
  defp if_regex(pattern, clause) do
    case Regex.compile(pattern) do
      {:ok, _} -> clause
      {:error, _} -> dynamic([i], false)
    end
  end

  # --- in-memory evaluation -------------------------------------------------------------------

  @doc "Evaluates the AST against an invocation struct or map (same semantics as the SQL)."
  @spec matches?(ast(), map(), keyword()) :: boolean()
  def matches?(ast, inv, opts \\ []) do
    inv = if is_struct(inv), do: Map.from_struct(inv), else: inv
    now = Keyword.get(opts, :now, DateTime.utc_now())
    Enum.all?(ast, fn term -> term_match?(term, inv, now) != term.neg end)
  end

  defp term_match?(%{key: nil, value: text}, inv, _now) do
    needle = String.downcase(text)

    [
      inv[:command],
      inv[:user_name],
      inv[:host],
      Enum.join(inv[:patterns] || [], " "),
      Jason.encode!(inv[:tags] || %{})
    ]
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
  end

  defp term_match?(%{key: key} = term, inv, now) do
    case Map.fetch(@columns, key) do
      {:ok, {:status, column}} -> string_match?(inv[column], normalize_status(term))
      {:ok, {:string, column}} -> string_match?(inv[column], term)
      {:ok, {:array, column}} -> array_match?(inv[column] || [], term)
      {:ok, {type, column}} -> typed_match?(type, inv[column], term, now)
      :error -> tag_match?((inv[:tags] || %{})[key], term)
    end
  end

  defp string_match?(nil, %{op: :neq}), do: true
  defp string_match?(nil, _term), do: false
  defp string_match?(actual, %{op: :exists}) when not is_nil(actual), do: true

  defp string_match?(actual, %{op: :eq, value: v}),
    do: String.downcase(to_string(actual)) == String.downcase(v)

  defp string_match?(actual, %{op: :neq, value: v}),
    do: String.downcase(to_string(actual)) != String.downcase(v)

  defp string_match?(actual, %{op: :in, value: values}),
    do: String.downcase(to_string(actual)) in Enum.map(values, &String.downcase/1)

  defp string_match?(actual, %{op: :regex, value: v}), do: safe_regex(v, to_string(actual))
  defp string_match?(_actual, _term), do: false

  defp array_match?(list, %{op: :exists}), do: list != []
  defp array_match?(list, %{op: :eq, value: v}), do: v in list
  defp array_match?(list, %{op: :neq, value: v}), do: v not in list
  defp array_match?(list, %{op: :in, value: values}), do: Enum.any?(values, &(&1 in list))
  defp array_match?(list, %{op: :regex, value: v}), do: Enum.any?(list, &safe_regex(v, &1))
  defp array_match?(_list, _term), do: false

  defp typed_match?(_type, nil, %{op: :neq}, _now), do: true
  defp typed_match?(_type, nil, _term, _now), do: false
  defp typed_match?(_type, _actual, %{op: :exists}, _now), do: true

  defp typed_match?(type, actual, %{op: :in, value: values}, now) do
    Enum.any?(values, fn v -> match?({:ok, ^actual}, typed(type, v, now)) end)
  end

  defp typed_match?(type, actual, %{op: op, value: v}, now)
       when op in [:eq, :neq, :gt, :gte, :lt, :lte] do
    case typed(type, v, now) do
      {:ok, value} -> cmp(op, actual, value)
      :error -> false
    end
  end

  defp typed_match?(_type, _actual, _term, _now), do: false

  defp tag_match?(nil, %{op: :neq}), do: true
  defp tag_match?(nil, _term), do: false
  defp tag_match?(_actual, %{op: :exists}), do: true

  defp tag_match?(actual, %{op: op, value: v}) when op in [:gt, :gte, :lt, :lte] do
    with {:ok, a} <- Values.number(actual),
         {:ok, b} <- Values.number(v),
         do: cmp(op, a * 1.0, b * 1.0),
         else: (_ -> false)
  end

  defp tag_match?(actual, term), do: string_match?(actual, term)

  defp cmp(:eq, a, b), do: compare_values(a, b) == :eq
  defp cmp(:neq, a, b), do: compare_values(a, b) != :eq
  defp cmp(:gt, a, b), do: compare_values(a, b) == :gt
  defp cmp(:gte, a, b), do: compare_values(a, b) in [:gt, :eq]
  defp cmp(:lt, a, b), do: compare_values(a, b) == :lt
  defp cmp(:lte, a, b), do: compare_values(a, b) in [:lt, :eq]

  defp compare_values(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare_values(a, b) when a < b, do: :lt
  defp compare_values(a, b) when a > b, do: :gt
  defp compare_values(_a, _b), do: :eq

  defp safe_regex(pattern, string) do
    case Regex.compile(pattern, "i") do
      {:ok, re} -> Regex.match?(re, string)
      _ -> false
    end
  end

  # --- shared ----------------------------------------------------------------------------------

  defp typed(:duration, v, _now), do: Values.duration(v)
  defp typed(:datetime, v, now), do: Values.datetime(v, now)
  defp typed(:integer, v, _now), do: Values.number(v)

  defp normalize_status(%{value: v} = term) when is_binary(v),
    do: %{term | value: Map.get(@status_aliases, String.downcase(v), v)}

  defp normalize_status(%{value: values} = term) when is_list(values),
    do: %{term | value: Enum.map(values, &Map.get(@status_aliases, String.downcase(&1), &1))}

  defp normalize_status(term), do: term

  defp escape_like(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")
end
