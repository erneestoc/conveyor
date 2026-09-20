#!/usr/bin/env bash
# Regenerates lib/conveyor_proto from the vendored .proto files.
# Requires: protoc (brew install protobuf) and protoc-gen-elixir (mix escript.install hex protobuf).
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.mix/escripts:$PATH"
OUT=lib/conveyor_proto
rm -rf "$OUT" && mkdir -p "$OUT"
INC="-I priv/protos/bazel -I priv/protos/googleapis -I priv/protos/remote-apis"
# google/api, google/rpc, google/longrunning and google/bytestream messages come from the
# `googleapis` hex package (a grpc_core dependency); they stay as protoc include paths only.
OPTS="--elixir_out=plugins=grpc:$OUT"
protoc $INC $OPTS \
  priv/protos/googleapis/google/devtools/build/v1/build_status.proto \
  priv/protos/googleapis/google/devtools/build/v1/build_events.proto \
  priv/protos/googleapis/google/devtools/build/v1/publish_build_event.proto \
  priv/protos/bazel/src/main/protobuf/option_filters.proto \
  priv/protos/bazel/src/main/protobuf/command_line.proto \
  priv/protos/bazel/src/main/protobuf/failure_details.proto \
  priv/protos/bazel/src/main/protobuf/strategy_policy.proto \
  priv/protos/bazel/src/main/protobuf/invocation_policy.proto \
  priv/protos/bazel/src/main/protobuf/action_cache.proto \
  priv/protos/bazel/src/main/protobuf/spawn.proto \
  priv/protos/bazel/src/main/java/com/google/devtools/build/lib/packages/metrics/package_load_metrics.proto \
  priv/protos/bazel/src/main/java/com/google/devtools/build/lib/buildeventstream/proto/build_event_stream.proto \
  priv/protos/remote-apis/build/bazel/semver/semver.proto \
  priv/protos/remote-apis/build/bazel/remote/execution/v2/remote_execution.proto
echo "generated $(find $OUT -name '*.pb.ex' | wc -l | tr -d ' ') files into $OUT"
