defmodule Conveyor.Grpc.FlowControl do
  @moduledoc """
  HTTP/2 flow control for request bodies that follows the reader.

  `grpc_server`'s stream handler (`grpc_stream_h`, a copy of `cowboy_stream_h` in which
  every read is in "auto" mode) answers every DATA frame with a `{flow, size}` command,
  whether or not the RPC process has asked for the body. Cowboy turns the command into
  WINDOW_UPDATE frames, so the client's window never closes: a handler that stops reading
  (a session holding its reply under back-pressure, a rate limit, a slow commit) does not
  slow Bazel down, and what it has not read piles up in the connection process without
  bound (measured: 8 MB sent to a stalled reader, 8 MB held).

  This module is a cowboy stream handler placed in front of that one. It passes
  everything through and removes the `flow` command of data that arrived while nobody was
  reading. The window for those bytes is granted when they are read: the inner handler
  already emits `{flow, byte_size(buffer)}` when a read finds data buffered. A read that
  finds nothing waits, and the frame that satisfies it carries its own `flow` as before.
  With a stalled reader the client can send what is left of its window (65,535 bytes
  initially, the last frame plus cowboy's 65,535-byte margin afterwards) and then waits.

  It is installed through the adapter's options (`adapter_opts/0`), which
  `GRPC.Server.Adapters.Cowboy` merges over its own `stream_handlers`. Nothing under
  `deps/` is edited; `flow_control_test.exs` stalls a reader against the real server and
  fails if an upgrade of `grpc_server` or `cowboy` brings the unbounded buffer back.
  """
  @behaviour :cowboy_stream

  @doc "Options for `GRPC.Server.Supervisor`'s `:adapter_opts`."
  @spec adapter_opts() :: keyword()
  def adapter_opts, do: [stream_handlers: [__MODULE__, :grpc_stream_h]]

  # {inner handler state, a read is waiting for data?, bytes buffered unread}
  @impl true
  def init(stream_id, req, opts) do
    {commands, next} = :cowboy_stream.init(stream_id, req, opts)
    {commands, {next, false, 0}}
  end

  @impl true
  def data(stream_id, fin, data, {next, true, _buffered}) do
    {commands, next} = :cowboy_stream.data(stream_id, fin, data, next)
    {commands, {next, false, 0}}
  end

  def data(stream_id, fin, data, {next, false, buffered}) do
    {commands, next} = :cowboy_stream.data(stream_id, fin, data, next)
    {Enum.reject(commands, &match?({:flow, _}, &1)), {next, false, buffered + byte_size(data)}}
  end

  @impl true
  def info(stream_id, {:read_body, _pid, _ref, _length, _period} = info, {next, _, buffered}) do
    {commands, next} = :cowboy_stream.info(stream_id, info, next)
    {commands, {next, buffered == 0, 0}}
  end

  def info(stream_id, info, {next, waiting?, buffered}) do
    {commands, next} = :cowboy_stream.info(stream_id, info, next)
    {commands, {next, waiting?, buffered}}
  end

  @impl true
  def terminate(stream_id, reason, {next, _, _}),
    do: :cowboy_stream.terminate(stream_id, reason, next)

  @impl true
  def early_error(stream_id, reason, partial_req, resp, opts),
    do: :cowboy_stream.early_error(stream_id, reason, partial_req, resp, opts)
end
