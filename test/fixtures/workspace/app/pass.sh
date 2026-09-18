#!/usr/bin/env bash
# Advertise sharding support so shard_count works.
[ -n "${TEST_SHARD_STATUS_FILE:-}" ] && touch "$TEST_SHARD_STATUS_FILE"
echo "pass_test: ok (shard ${TEST_SHARD_INDEX:-0}/${TEST_TOTAL_SHARDS:-1})"
sleep 0.5
exit 0
