defmodule Conveyor.Grpc.ActionCacheServer do
  @moduledoc """
  `ActionCache` for the CAS sink. Conveyor stores no action results: every lookup is a
  miss and updates are refused, so Bazel keeps executing locally while still uploading
  BEP files here. Users should also pass `--remote_upload_local_results=false`.
  """
  use GRPC.Server, service: Build.Bazel.Remote.Execution.V2.ActionCache.Service

  alias Build.Bazel.Remote.Execution.V2, as: RE
  alias Conveyor.Grpc.ByteStreamServer

  def get_action_result(%RE.GetActionResultRequest{action_digest: digest}, _stream) do
    ByteStreamServer.sink_enabled!()
    hash = if digest, do: digest.hash, else: "?"
    raise GRPC.RPCError, status: :not_found, message: "no action result for #{hash}"
  end

  def update_action_result(%RE.UpdateActionResultRequest{}, _stream) do
    ByteStreamServer.sink_enabled!()

    raise GRPC.RPCError,
      status: :permission_denied,
      message: "the CAS sink stores no action results; pass --remote_upload_local_results=false"
  end
end
