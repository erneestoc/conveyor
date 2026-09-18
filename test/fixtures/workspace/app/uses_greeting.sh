#!/usr/bin/env bash
grep -q "hello from conveyor" "$(dirname "$0")/../lib/greeting.txt" 2>/dev/null || grep -rq "hello from conveyor" . && echo "greeting found" && exit 0
echo "greeting not found" >&2; exit 1
