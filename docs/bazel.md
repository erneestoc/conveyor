# Configuring Bazel for Conveyor

Add to `.bazelrc` (workspace or `~/.bazelrc`). Conveyor speaks the standard Build Event
Service protocol, so nothing is installed on the client.

```
# Where builds go and where the link in the terminal points
build --bes_backend=grpcs://conveyor.example.com:1985
build --bes_results_url=https://conveyor.example.com/invocation/

# Authentication: an API key created in Settings (or `mix run` on the server)
build --bes_header=x-api-key=conveyor_xxxxxxxx_...

# Tags you can filter and chart by (lowercased; reserved keys get a user. prefix)
build --build_metadata=TEAM=infra
build:ci --build_metadata=CI=true --build_metadata=BRANCH=$BRANCH_NAME

# Survive a rolling restart of the server (Bazel's default retry budget is seconds)
build --build_event_upload_max_retries=10

# Only test logs and the profile are uploaded to the remote cache; outputs stay local
build --remote_build_event_upload=minimal
```

## Does streaming slow the build down?

No. Bazel sends events on a background thread while actions run. What can cost time is
the end of the command, controlled by `--bes_upload_mode`:

| Mode | Behaviour | Use |
|---|---|---|
| `wait_for_upload_complete` (default) | The command returns once every event is acknowledged and files are uploaded. Against a healthy Conveyor the wait is the last ack, a few hundred milliseconds. | CI: the job's success means the results are stored. Set `--bes_timeout=120s`; the default is no timeout, so an unreachable server would hang the exit. |
| `nowait_for_upload_complete` | The command returns immediately; the persistent Bazel server finishes the upload. The next invocation waits for it first. | Developers' machines. `bazel shutdown` right after a build can drop an upload still in flight. |
| `fully_async` | As above, and the next invocation does not wait either. Upload failures never affect an exit code. | Only when the results are best-effort. |

```
build:ci  --bes_upload_mode=wait_for_upload_complete --bes_timeout=120s
build:dev --bes_upload_mode=nowait_for_upload_complete --bes_timeout=30s
```

Event volume is what costs the server and the network. `--build_event_publish_all_actions`
emits one event per action (two with the progress event behind each), 1.7 to 2.3 KB on
the wire per action, mostly the command line. Conveyor takes it as follows: only failed
actions appear in a build's Actions tab, with or without the flag; the events of
successful actions are counted and, by default, not stored with the build's raw events
(its Events tab says how many; the project setting "Keep per-action events in the raw
event stream" on the Duplicate work page stores them, at 84 to 170 stored bytes per
action in recorded builds). The duplicate-work metrics do not read these events yet;
they still come from execution logs (below).

## Profiles, test logs and artifacts

With `--remote_cache` set, Bazel uploads the build profile (`command.profile.gz`) and each
test's `test.log` / `test.xml` to the cache and references them in the event stream.
Conveyor fetches them from the cache endpoint configured in Settings and renders the
timeline and test outputs.

Without a remote cache, run with `--remote_cache=grpcs://conveyor.example.com:1985`
(Conveyor's built-in CAS sink, `CAS_SINK_ENABLED=true`) together with
`--remote_upload_local_results=false --noremote_accept_cached`, so Bazel uploads only the
referenced files and never treats Conveyor as a cache for outputs. Or upload a profile
after the fact with `tools/bes-upload-profile`.

## Why did it rebuild? (execution log)

Bazel's compact execution log records every spawn with the digest of each input and
output, its runner, cache status and timings. Conveyor diffs it against the previous build
of the same project (same `branch` tag when the build has one) and shows, per spawn, the
inputs that changed, the spawns that ran again with identical inputs (cache misses or
non-hermetic actions — "outputs differ" flags the latter), and new actions.

```
build --execution_log_compact_file=/tmp/exec.log.zst
```

After the build, upload the file to the invocation (an `upload`-scoped key):

```sh
tools/bes-upload-profile --server https://conveyor.example.com --key conveyor_... \
    --invocation <uuid> --execution-log /tmp/exec.log.zst
# or: curl -X PUT -H "x-api-key: conveyor_..." --data-binary @/tmp/exec.log.zst \
#        https://conveyor.example.com/api/v1/invocations/<uuid>/artifacts/execution.log.zst
```

Any artifact name containing `execution.log`, `exec_log` or `execlog` is parsed. The log
only lists spawns that ran or were served from the remote cache; actions skipped by
Bazel's local action cache do not appear, so a fully incremental build has an empty log.

## Duplicate work: execution logs for whole pipelines

The [Duplicate work](duplicate-work.md) report finds duplicate work between builds, so
it needs the execution log of **every build of a pipeline run** (all shards, all jobs),
not of a sample of builds. Sample by pipeline: enable it for all jobs of, say, one
pipeline in ten, or of the main branch.

Projects that upload logs only for this report can keep less of each one: the page's
setting "Keep only what the duplicate-work metrics need" stores no input lists, deletes
the uploaded log once it is parsed and keeps per-spawn rows for a few days
([what it gives up](duplicate-work.md#keeping-only-what-the-metrics-need)). Upload each
log within those days of its build's start: a log parsed later is not counted.

```
# .bazelrc of the CI jobs
build --execution_log_compact_file=/tmp/exec.log.zst
build --build_metadata=PIPELINE=<pipeline run id>   # optional: racing per pipeline
build --build_metadata=COMMIT=<sha>                 # optional: near misses
```

| Bazel | Flag | Status |
|---|---|---|
| 8, 9 | `--execution_log_compact_file` | recorded with 9.2 for this repository's fixtures |
| 7.1 and later 7.x | `--experimental_execution_log_compact_file` | not exercised here; check `bazel help build` |
| 7.0 and earlier | no compact log | `--execution_log_binary_file` is another format and is not parsed |

After each build, upload the file to its invocation with an `upload`-scoped key:

```sh
tools/bes-upload-profile --server https://conveyor.example.com --key conveyor_... \
    --invocation "$INVOCATION_ID" --execution-log /tmp/exec.log.zst
```

Set `--invocation_id=$(uuidgen)` yourself (lowercase) so the job knows the id, or read it
from the results URL Bazel prints.

Without the tool, with curl (the Duplicate work page shows this recipe with your
server's address, and says whether the project has a key that may upload):

```sh
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
  -H "x-api-key: $CONVEYOR_UPLOAD_KEY" \
  -H "content-type: application/octet-stream" \
  --data-binary @/tmp/exec.log.zst \
  "https://conveyor.example.com/api/v1/invocations/$ID/artifacts/execution.log.zst")
echo "execution log upload: HTTP $code"
```

**The key needs the `upload` scope.** A key with only `ingest` and `read` (what a BES
key usually has) is answered `403 API key lacks the upload scope`; in a `curl -sf`
pipeline that is silent, which is why the recipe prints the status. `201` means stored;
the log is parsed in the background. The `content-type` header is required (curl's
default form encoding is refused).

The flag does not change cache keys: with Bazel 9.2 (checked 2026-11-22) a build without
it hit every action cached by a build with it, and toggling it did not discard the
analysis cache.

### Declaring cores with `exec_properties`

Core time is wall time × cores, and the only per-action statement of cores the compact
execution log can carry is a property of the spawn's execution platform
(`ExecLogEntry.Spawn.platform`, name/value pairs; checked in the vendored
`spawn.proto`). Bazel fills it from the action's exec properties. On a test target:

```python
go_test(
    name = "integration_test",
    srcs = ["integration_test.go"],
    exec_properties = {"cores": "4"},
)
```

For every action that runs on an execution platform:

```python
platform(
    name = "rbe_linux",
    constraint_values = ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    exec_properties = {
        "OSFamily": "linux",
        "cores": "2",
    },
)
# build --extra_execution_platforms=//platforms:rbe_linux
```

Then tell Conveyor the name and its unit in the settings panel of the project's Duplicate work page
([Declaring cores per action](duplicate-work.md#declaring-cores-per-action)): names in
order, first present wins, any case; unit `cores`, `millicores` or `auto`. If you do not
know which name your builds send, upload one log and read the list of property names on
the settings panel. A changed setting applies to logs parsed afterwards; the "Re-read
cores from stored logs" button applies it to builds already parsed.

**Unverified** (Bazel behaviour not exercised against this repository; the recorded
fixtures have no platform on any spawn):

- that a target's `exec_properties` are merged over the platform's, the target winning
  per key, and that the merged set is what the log's `platform` holds for locally
  executed and sandboxed spawns as well as remote ones;
- that `exec_properties` on a test target reach the `TestRunner` spawn without an exec
  group prefix (test actions may run in a `test` exec group, for which the key would
  be `"test.cores"`; if the test runner's spawns show no property, try that);
- `--remote_default_exec_properties=cores=2` as a way to set a default without a
  platform target;
- what your RBE backend does with the property: the name that sizes a worker is the
  backend's (`cores`, `cpu`, `EstimatedCPU`, a pool name…). Conveyor only reads it.

Check with one build: the settings panel lists the names that arrived.

What makes the numbers exact:

- **One key source per project.** With `--remote_cache`, `--disk_cache` or
  `--remote_executor` Bazel writes the action digest of every spawn into the log; without
  any of them it does not and Conveyor computes a key of its own. Do not mix both kinds of
  job in one project.
- **Cores per action.** The log has wall time and no CPU time. It carries the cores of an
  action only as a platform property: `exec_properties = {"cores": "4"}` on the target or
  the execution platform ([above](#declaring-cores-with-exec_properties); the name and
  unit are a project setting). A `cpu:4` tag does not reach the compact log (Conveyor reads it
  from the event stream for test targets instead); otherwise set `TestRunner=4` in the
  page's settings.
- **Clocks.** Racing against sequential is decided by the machines' clocks; keep them on
  NTP and set the project's tolerance.
- **Grouping.** Shards of one pipeline need nothing: they are builds of one project and
  are compared by action key and time. Apps that are separate projects are compared when
  a global admin puts them into one cache group. `--build_metadata` keys become tags
  (lowercased); `--bes_keywords=user_keyword=pipeline=123` works too.

Volume: the log is a few bytes per spawn compressed (megabytes for a large clean build);
in the database a build with a log costs a few megabytes until `RETENTION_SPAWN_DAYS`
(30) removes its spawns, of which this analysis is about 150 bytes per executed spawn
plus 230 per distinct action. Writing the log costs Bazel little; the upload is one PUT
per build.

Savings on the page are core time of actions, not build minutes.

## Versions

Conveyor's protocol definitions come from Bazel 9.2 and are backwards compatible; builds
from Bazel 7 and 8 are exercised in CI (`.github/workflows/e2e.yml`).
