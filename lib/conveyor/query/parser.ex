defmodule Conveyor.Query.Parser do
  @moduledoc """
  Parses the build search language into a list of terms.

      user:alice ci:true -status:succeeded command:test duration>5m started>-7d "//app/..."

      key:value          equality (case-insensitive)     key:(a,b,c)  any of
      key!=value         not equal                        -term        negate
      key>v key<v key>=v key<=v   numeric, duration (5m, 2h30m) or date (2026-09-01, -24h)
      key~regex          regular expression (case-insensitive)
      key:*              key present
      "free text"        matched against patterns, command, user, host and tags

  Keys are `[A-Za-z0-9_.-]+`; anything else is free text. Values may be quoted.
  """

  @type term_ast :: %{
          neg: boolean(),
          key: String.t() | nil,
          op: atom(),
          value: String.t() | [String.t()] | nil
        }

  @ops [
    {"!=", :neq},
    {">=", :gte},
    {"<=", :lte},
    {":", :eq},
    {"=", :eq},
    {">", :gt},
    {"<", :lt},
    {"~", :regex}
  ]
  @key_re ~r/^[A-Za-z0-9_.\-]+$/

  @doc "Parses a query string. Returns `{:ok, terms}` or `{:error, message}`."
  @spec parse(String.t() | nil) :: {:ok, [term_ast()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(string) when is_binary(string) do
    with {:ok, tokens} <- tokenize(string) do
      tokens
      |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
        case parse_token(token) do
          {:ok, term} -> {:cont, {:ok, [term | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, terms} -> {:ok, Enum.reverse(terms)}
        error -> error
      end
    end
  end

  # Splits on whitespace, keeping quoted strings and parenthesised lists together.
  @doc false
  def tokenize(string), do: tokenize(String.trim(string), [], "", nil)

  defp tokenize("", tokens, "", nil), do: {:ok, Enum.reverse(tokens)}
  defp tokenize("", tokens, current, nil), do: {:ok, Enum.reverse([current | tokens])}
  defp tokenize("", _tokens, _current, ?"), do: {:error, "unterminated quote"}
  defp tokenize("", _tokens, _current, ?(), do: {:error, "unterminated list"}

  defp tokenize(<<?", rest::binary>>, tokens, current, nil),
    do: tokenize(rest, tokens, current <> "\"", ?")

  defp tokenize(<<?", rest::binary>>, tokens, current, ?"),
    do: tokenize(rest, tokens, current <> "\"", nil)

  defp tokenize(<<?\\, ?", rest::binary>>, tokens, current, ?"),
    do: tokenize(rest, tokens, current <> "\\\"", ?")

  defp tokenize(<<?\\, ?\\, rest::binary>>, tokens, current, ?"),
    do: tokenize(rest, tokens, current <> "\\\\", ?")

  defp tokenize(<<?(, rest::binary>>, tokens, current, nil),
    do: tokenize(rest, tokens, current <> "(", ?()

  defp tokenize(<<?), rest::binary>>, tokens, current, ?(),
    do: tokenize(rest, tokens, current <> ")", nil)

  defp tokenize(<<c, rest::binary>>, tokens, current, nil) when c in [?\s, ?\t, ?\n] do
    if current == "",
      do: tokenize(rest, tokens, "", nil),
      else: tokenize(rest, [current | tokens], "", nil)
  end

  defp tokenize(<<c::utf8, rest::binary>>, tokens, current, mode),
    do: tokenize(rest, tokens, current <> <<c::utf8>>, mode)

  @doc false
  def parse_token("-" <> rest) when rest != "" do
    with {:ok, term} <- parse_token(rest), do: {:ok, %{term | neg: true}}
  end

  def parse_token(token) do
    case split_operator(token) do
      {key, op, value} ->
        if Regex.match?(@key_re, key), do: build(key, op, value), else: {:ok, text(token)}

      nil ->
        {:ok, text(token)}
    end
  end

  defp split_operator(token) do
    # The operator is the earliest occurrence; among operators starting at the same index the
    # longest wins (so "!=" beats "=" and ">=" beats ">").
    @ops
    |> Enum.map(fn {op, atom} ->
      case :binary.match(token, op) do
        {idx, _} -> {idx, -byte_size(op), op, atom}
        :nomatch -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
    |> case do
      nil ->
        nil

      {0, _, _, _} ->
        nil

      {idx, _, op, atom} ->
        {binary_part(token, 0, idx), atom,
         binary_part(token, idx + byte_size(op), byte_size(token) - idx - byte_size(op))}
    end
  end

  defp build(key, :eq, "*"),
    do: {:ok, %{neg: false, key: String.downcase(key), op: :exists, value: nil}}

  defp build(_key, _op, ""), do: {:error, "missing value"}

  defp build(key, op, "(" <> rest) do
    if op in [:eq, :neq] and String.ends_with?(rest, ")") do
      values =
        rest
        |> String.trim_trailing(")")
        |> String.split(",")
        |> Enum.map(&unquote_value/1)
        |> Enum.reject(&(&1 == ""))

      if values == [],
        do: {:error, "empty list"},
        else: {:ok, %{neg: op == :neq, key: String.downcase(key), op: :in, value: values}}
    else
      {:error, "lists only work with : or !="}
    end
  end

  defp build(key, op, value),
    do: {:ok, %{neg: false, key: String.downcase(key), op: op, value: unquote_value(value)}}

  defp text(token), do: %{neg: false, key: nil, op: :text, value: unquote_value(token)}

  defp unquote_value(value) do
    value = String.trim(value)

    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
         byte_size(value) >= 2 do
      value |> binary_part(1, byte_size(value) - 2) |> String.replace(~r/\\(["\\])/, "\\1")
    else
      value
    end
  end

  @doc "Renders terms back to a query string (used to add facets to a query)."
  @spec to_query_string([term_ast()]) :: String.t()
  def to_query_string(terms), do: Enum.map_join(terms, " ", &term_to_string/1)

  defp term_to_string(%{neg: neg} = term) do
    prefix = if neg and term.op != :in, do: "-", else: ""
    prefix <> term_body(term)
  end

  defp term_body(%{key: nil, value: v}), do: quote_value(v)
  defp term_body(%{key: k, op: :exists}), do: "#{k}:*"

  defp term_body(%{key: k, op: :in, neg: neg, value: values}),
    do: "#{k}#{if neg, do: "!=", else: ":"}(#{Enum.join(values, ",")})"

  defp term_body(%{key: k, op: op, value: v}), do: "#{k}#{op_string(op)}#{quote_value(v)}"

  defp op_string(:eq), do: ":"
  defp op_string(:neq), do: "!="
  defp op_string(:gt), do: ">"
  defp op_string(:gte), do: ">="
  defp op_string(:lt), do: "<"
  defp op_string(:lte), do: "<="
  defp op_string(:regex), do: "~"

  # Quote whatever would not read back as the same equality term: empty values, `*`
  # (the exists operator), values with whitespace, quotes or parentheses, and values
  # starting with an operator character.
  defp quote_value(v) when is_binary(v) do
    if v == "" or v == "*" or String.contains?(v, [" ", "\t", "\"", "(", ")", "\\"]) or
         String.starts_with?(v, ["!", "<", ">", "=", "~", ":"]),
       do: "\"" <> String.replace(v, ~r/(["\\])/, "\\\\\\1") <> "\"",
       else: v
  end
end
