defmodule Conveyor.Artifacts.Junit do
  @moduledoc """
  Parses JUnit-style `test.xml` reports (what Bazel's test runner writes) into suites and
  cases. Uses OTP's SAX parser with external entities disabled, so a hostile report
  cannot make the server read files or fetch URLs.
  """

  @type test_case :: %{
          name: String.t(),
          classname: String.t() | nil,
          time_ms: integer() | nil,
          status: :passed | :failed | :error | :skipped,
          message: String.t() | nil
        }
  @type suite :: %{
          name: String.t(),
          tests: integer(),
          failures: integer(),
          errors: integer(),
          skipped: integer(),
          time_ms: integer() | nil,
          cases: [test_case()],
          system_out: String.t() | nil
        }

  @spec parse(binary()) :: {:ok, [suite()]} | {:error, String.t()}
  def parse(xml) when is_binary(xml) do
    opts = [
      {:event_fun, &event/3},
      {:event_state, %{suites: [], suite: nil, case: nil, text: nil, in: []}},
      {:external_entities, :none},
      {:fail_undeclared_ref, false}
    ]

    case :xmerl_sax_parser.stream(xml, opts) do
      {:ok, state, _rest} ->
        {:ok, state.suites |> Enum.reverse() |> Enum.map(&finish_suite/1)}

      {:fatal_error, _location, reason, _tags, _state} ->
        {:error, "malformed XML: #{format_reason(reason)}"}

      {tag, _location, reason, _tags, _state} when tag in [:error, :fatal] ->
        {:error, "malformed XML: #{format_reason(reason)}"}

      other ->
        {:error, "malformed XML: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "malformed XML: #{Exception.message(e)}"}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_list(reason), do: List.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp event({:startElement, _, ~c"testsuite", _, attrs}, _loc, st) do
    a = attributes(attrs)

    suite = %{
      name: a["name"] || "",
      tests: int(a["tests"]),
      failures: int(a["failures"]),
      errors: int(a["errors"]),
      skipped: int(a["skipped"]) + int(a["disabled"]),
      time_ms: time_ms(a["time"]),
      cases: [],
      system_out: nil
    }

    %{st | suite: suite, in: [:suite | st.in]}
  end

  defp event({:endElement, _, ~c"testsuite", _}, _loc, %{suite: suite} = st) when suite != nil do
    %{st | suites: [suite | st.suites], suite: nil, in: tl(st.in)}
  end

  defp event({:startElement, _, ~c"testcase", _, attrs}, _loc, %{suite: suite} = st)
       when suite != nil do
    a = attributes(attrs)

    tc = %{
      name: a["name"] || "",
      classname: a["classname"],
      time_ms: time_ms(a["time"]),
      status: :passed,
      message: nil
    }

    %{st | case: tc, in: [:case | st.in]}
  end

  defp event({:endElement, _, ~c"testcase", _}, _loc, %{case: tc, suite: suite} = st)
       when tc != nil do
    %{st | suite: %{suite | cases: [tc | suite.cases]}, case: nil, in: tl(st.in)}
  end

  defp event({:startElement, _, name, _, attrs}, _loc, %{case: tc} = st)
       when tc != nil and name in [~c"failure", ~c"error", ~c"skipped"] do
    status = %{~c"failure" => :failed, ~c"error" => :error, ~c"skipped" => :skipped}[name]
    a = attributes(attrs)
    %{st | case: %{tc | status: status, message: a["message"]}, text: [], in: [:verdict | st.in]}
  end

  defp event({:endElement, _, name, _}, _loc, %{case: tc, text: text} = st)
       when tc != nil and name in [~c"failure", ~c"error", ~c"skipped"] do
    body = text |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    message = tc.message || if(body == "", do: nil, else: String.slice(body, 0, 2000))
    %{st | case: %{tc | message: message}, text: nil, in: tl(st.in)}
  end

  defp event(
         {:startElement, _, ~c"system-out", _, _},
         _loc,
         %{suite: suite, in: [:suite | _]} = st
       )
       when suite != nil,
       do: %{st | text: [], in: [:out | st.in]}

  defp event({:endElement, _, ~c"system-out", _}, _loc, %{in: [:out | rest], suite: suite} = st) do
    out = st.text |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    %{st | suite: %{suite | system_out: if(out == "", do: nil, else: out)}, text: nil, in: rest}
  end

  defp event({:characters, chars}, _loc, %{text: text} = st) when is_list(text),
    do: %{st | text: [List.to_string(chars) | text]}

  defp event(_event, _loc, st), do: st

  defp attributes(attrs) do
    Map.new(attrs, fn {_uri, _prefix, name, value} ->
      {List.to_string(name), List.to_string(value)}
    end)
  end

  defp int(nil), do: 0

  defp int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp time_ms(nil), do: nil

  defp time_ms(s) do
    case Float.parse(s) do
      {f, _} -> round(f * 1000)
      :error -> nil
    end
  end

  defp finish_suite(suite), do: %{suite | cases: Enum.reverse(suite.cases)}
end
