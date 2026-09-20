#!/usr/bin/env bash
# One trial task: clone a project, then run a sequence of workload steps in one Bazel
# output base, streaming every build to Conveyor. Inputs (environment):
#   PROJECT  short name used in tags            REPO     git URL          REF   branch/tag/commit
#   SUBDIR   workspace directory inside the repo (optional)
#   TARGETS  build targets (default //...)      TEST_TARGETS  test targets (default: TARGETS)
#   MODE     local | cache | rbe                WORKLOAD  comma list of steps (default clean,noop,leaf,wide,buildfile,test)
#   WAVE     free-form tag for the run          TAGS      extra build_metadata "k=v,k=v"
#   BAZEL_FLAGS extra flags                     USE_BAZEL_VERSION  bazelisk pin (optional)
# From the task definition: CONVEYOR_SERVER, BES_BACKEND, REMOTE_CACHE, REMOTE_EXECUTOR,
# SSM_PREFIX, AWS_REGION. Secrets come from SSM: $SSM_PREFIX/api-key and $SSM_PREFIX/ca.crt.
set -uo pipefail

: "${PROJECT:?}" "${REPO:?}"
REF="${REF:-HEAD}"
TARGETS="${TARGETS:-//...}"
TEST_TARGETS="${TEST_TARGETS:-$TARGETS}"
MODE="${MODE:-local}"
WORKLOAD="${WORKLOAD:-clean,noop,leaf,wide,buildfile,test}"
WAVE="${WAVE:-manual}"
TAGS="${TAGS:-}"
BAZEL_FLAGS="${BAZEL_FLAGS:-}"

log() { echo "[trial $(date -u +%H:%M:%S)] $*"; }

api_key=$(aws ssm get-parameter --region "$AWS_REGION" --name "$SSM_PREFIX/api-key" --with-decryption --query Parameter.Value --output text)
aws ssm get-parameter --region "$AWS_REGION" --name "$SSM_PREFIX/ca.crt" --query Parameter.Value --output text > /tmp/rbe-ca.crt
# Bazel's --tls_certificate replaces the trust store for every gRPC channel, so the bundle
# must hold the public roots (Conveyor's ACM certificate) and the trial CA (NativeLink).
cat /etc/ssl/certs/ca-certificates.crt /tmp/rbe-ca.crt > /tmp/tls-bundle.pem

log "cloning $REPO@$REF"
git clone --quiet --depth 50 "$REPO" /work/src && cd /work/src || { log "clone failed"; exit 1; }
if [[ "$REF" != "HEAD" ]]; then git fetch --quiet --depth 50 origin "$REF" && git checkout --quiet FETCH_HEAD || git checkout --quiet "$REF"; fi
commit=$(git rev-parse --short HEAD)
[[ -n "${SUBDIR:-}" ]] && cd "/work/src/$SUBDIR"
log "workspace $(pwd) at $commit, mode=$MODE workload=$WORKLOAD"

common=(
  --bes_backend="$BES_BACKEND" --bes_results_url="$CONVEYOR_SERVER/invocation/"
  --bes_header="x-api-key=$api_key" --bes_upload_mode=wait_for_upload_complete --bes_timeout=180s
  --build_event_upload_max_retries=10 --tls_certificate=/tmp/tls-bundle.pem
  --build_metadata=project="$PROJECT" --build_metadata=mode="$MODE" --build_metadata=wave="$WAVE"
  --build_metadata=commit="$commit" --build_metadata=ci=true --build_metadata=branch=main
  --build_metadata=USER=trial --build_metadata=team=trial --build_metadata=host="$(hostname)"
  --generate_json_trace_profile --execution_log_compact_file=/tmp/exec.log.zst
  --remote_timeout=3600 --show_progress_rate_limit=5 --curses=no --color=yes
)
IFS=',' read -ra extra <<< "$TAGS"
for kv in "${extra[@]}"; do [[ -n "$kv" ]] && common+=(--build_metadata="$kv"); done
case "$MODE" in
  cache) common+=(--remote_cache="$REMOTE_CACHE" --remote_upload_local_results=true) ;;
  rbe)   common+=(--remote_cache="$REMOTE_CACHE" --remote_executor="$REMOTE_EXECUTOR"
                  --remote_default_exec_properties=OSFamily=Linux --jobs=64) ;;
esac
read -ra flags <<< "$BAZEL_FLAGS"

upload() { # invocation id, name, file
  [[ -s "$3" ]] || return 0
  curl -sf -X PUT -H "x-api-key: $api_key" -H "content-type: application/octet-stream" \
    --data-binary @"$3" "$CONVEYOR_SERVER/api/v1/invocations/$1/artifacts/$2" >/dev/null \
    && log "uploaded $2 to $1" || log "upload of $2 failed"
}

run_bazel() { # step, command, targets...
  local step="$1" cmd="$2"; shift 2
  local id; id=$(cat /proc/sys/kernel/random/uuid)
  local profile=/tmp/profile-$step.gz
  rm -f /tmp/exec.log.zst
  log "step=$step bazel $cmd $* (invocation $id)"
  bazel "$cmd" "$@" "${common[@]}" "${flags[@]}" --invocation_id="$id" \
    --build_metadata=workload="$step" --profile="$profile" 2>&1 | tail -n 40
  local code=${PIPESTATUS[0]}
  log "step=$step exit=$code"
  upload "$id" execution.log.zst /tmp/exec.log.zst
  # Without a remote cache the profile is not referenced from the stream: attach it.
  [[ "$MODE" == "local" ]] && upload "$id" command.profile.gz "$profile"
  echo "$step $id $code" >> /tmp/results.txt
}

touch_file() { # append a harmless line to a source file
  local f="$1"
  case "$f" in
    *.py|*.sh|*.bzl|BUILD|BUILD.bazel|*.bazel|*.txt|*.toml|*.yaml|*.yml) printf '\n# conveyor trial %s\n' "$(date +%s)" >> "$f" ;;
    *) printf '\n// conveyor trial %s\n' "$(date +%s)" >> "$f" ;;
  esac
  log "modified $f"
}

sources() { git ls-files | grep -E '\.(cc|cpp|c|h|hpp|go|rs|java|py|ts|proto)$' | grep -vE '(^|/)(test|tests|testdata|third_party|external)/' ; }

pick_leaf() { sources | grep -vE '\.(h|hpp)$' | shuf -n1 --random-source=<(yes); }

# The source file whose stem is mentioned in the most other files: a widely-included
# header in C++, a widely-imported module elsewhere.
pick_wide() {
  local best="" best_n=0
  while read -r f; do
    local stem; stem=$(basename "$f"); stem="${stem%%.*}"
    [[ ${#stem} -lt 4 ]] && continue
    local n; n=$(git grep -lw --cached "$stem" -- ':!*.md' 2>/dev/null | wc -l)
    (( n > best_n )) && { best_n=$n; best="$f"; }
  done < <(sources | grep -E '\.(h|hpp|go|rs|java|py|proto)$' | shuf -n 40 --random-source=<(yes))
  [[ -n "$best" ]] && echo "$best" || pick_leaf
}

pick_buildfile() { git ls-files | grep -E '(^|/)BUILD(\.bazel)?$' | shuf -n1 --random-source=<(yes); }

IFS=',' read -ra steps <<< "$WORKLOAD"
for step in "${steps[@]}"; do
  case "$step" in
    clean)     bazel clean --expunge >/dev/null 2>&1; run_bazel clean build "$TARGETS" ;;
    noop)      run_bazel noop build "$TARGETS" ;;
    leaf)      f=$(pick_leaf); [[ -n "$f" ]] && touch_file "$f"; run_bazel leaf build "$TARGETS" ;;
    wide)      f=$(pick_wide); [[ -n "$f" ]] && touch_file "$f"; run_bazel wide build "$TARGETS" ;;
    buildfile) f=$(pick_buildfile); [[ -n "$f" ]] && touch_file "$f"; run_bazel buildfile build "$TARGETS" ;;
    test)      run_bazel test test "$TEST_TARGETS" ;;
    *)         log "unknown step $step" ;;
  esac
done
log "done:"; cat /tmp/results.txt
bazel shutdown >/dev/null 2>&1 || true
exit 0
