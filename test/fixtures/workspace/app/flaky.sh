#!/usr/bin/env bash
# Deterministically flaky: the first attempt of a build fails and leaves a marker,
# the next attempt sees the marker, removes it and passes. Runs with the "local" tag
# so it is not sandboxed and can keep the marker in /tmp.
marker="/tmp/conveyor_fixture_flaky_marker"
if [ -f "$marker" ]; then rm -f "$marker"; echo "flaky_test: second attempt passes"; exit 0; fi
touch "$marker"; echo "flaky_test: first attempt fails" >&2; exit 1
