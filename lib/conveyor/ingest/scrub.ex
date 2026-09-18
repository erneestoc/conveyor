defmodule Conveyor.Ingest.Scrub do
  @moduledoc """
  Removes credentials from BEP events before they are persisted.

  Bazel echoes its command line (including `--bes_header=x-api-key=...` and
  `--remote_header=...`) into `UnstructuredCommandLine`, `StructuredCommandLine`,
  `OptionsParsed`, `BuildStarted.options_description` and the progress log. Those values
  are rewritten to `<redacted>` in the decoded event, and the caller stores the
  re-encoded bytes, so no secret reaches the database.
  """

  alias BuildEventStream.BuildEvent, as: BepEvent

  @redacted "<redacted>"

  @header_flags ~w(bes_header remote_header remote_exec_header remote_cache_header remote_downloader_header remote_proxy_header bes_proxy_header)
  @header_re ~r/(--(?:#{Enum.join(@header_flags, "|")})=[^=\s]+=)([^\s]*)/
  @url_cred_re ~r{(://)[^/@\s:]+:[^/@\s]+@}
  @generic_re ~r/((?:token|secret|password|passwd|api[_-]?key|authorization)=)([^\s&"']+)/i
  @bearer_re ~r/(Bearer\s+)[A-Za-z0-9\-._~+\/]+=*/i

  @doc "Scrubs one string."
  @spec text(String.t() | nil) :: String.t() | nil
  def text(nil), do: nil

  def text(string) when is_binary(string) do
    string
    |> then(&Regex.replace(@header_re, &1, "\\1#{@redacted}"))
    |> then(&Regex.replace(@url_cred_re, &1, "\\1#{@redacted}@"))
    |> then(&Regex.replace(@generic_re, &1, "\\1#{@redacted}"))
    |> then(&Regex.replace(@bearer_re, &1, "\\1#{@redacted}"))
  end

  @doc "Scrubs a list of strings (command line arguments)."
  @spec args([String.t()]) :: [String.t()]
  def args(list), do: Enum.map(list, &text/1)

  @doc """
  Scrubs a decoded BEP event. Returns `{event, changed?}`; when `changed?` is true the
  caller must re-encode the event instead of storing the original bytes.
  """
  @spec event(BepEvent.t()) :: {BepEvent.t(), boolean()}
  def event(%BepEvent{payload: {:started, started}} = ev) do
    put_payload(ev, :started, %{started | options_description: text(started.options_description)})
  end

  def event(%BepEvent{payload: {:unstructured_command_line, cl}} = ev) do
    put_payload(ev, :unstructured_command_line, %{cl | args: args(cl.args)})
  end

  def event(%BepEvent{payload: {:structured_command_line, cl}} = ev) do
    sections =
      Enum.map(cl.sections, fn
        %{section_type: {:option_list, ol}} = section ->
          options =
            Enum.map(
              ol.option,
              &%{&1 | combined_form: text(&1.combined_form), option_value: text(&1.option_value)}
            )

          %{section | section_type: {:option_list, %{ol | option: options}}}

        %{section_type: {:chunk_list, chunks}} = section ->
          %{section | section_type: {:chunk_list, %{chunks | chunk: args(chunks.chunk)}}}

        section ->
          section
      end)

    put_payload(ev, :structured_command_line, %{cl | sections: sections})
  end

  def event(%BepEvent{payload: {:options_parsed, op}} = ev) do
    put_payload(ev, :options_parsed, %{
      op
      | startup_options: args(op.startup_options),
        explicit_startup_options: args(op.explicit_startup_options),
        cmd_line: args(op.cmd_line),
        explicit_cmd_line: args(op.explicit_cmd_line)
    })
  end

  def event(%BepEvent{payload: {:progress, progress}} = ev) do
    put_payload(ev, :progress, %{
      progress
      | stdout: text(progress.stdout),
        stderr: text(progress.stderr)
    })
  end

  def event(%BepEvent{payload: {:action, action}} = ev) do
    put_payload(ev, :action, %{action | command_line: args(action.command_line)})
  end

  def event(%BepEvent{} = ev), do: {ev, false}

  defp put_payload(%BepEvent{payload: {kind, old}} = ev, kind, new) do
    if new == old, do: {ev, false}, else: {%{ev | payload: {kind, new}}, true}
  end
end
