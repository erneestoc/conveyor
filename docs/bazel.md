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

Event volume is what costs the server and the network: `--build_event_publish_all_actions`
emits one event per action and multiplies the stream for large builds; leave it off unless
you want every action in the Actions tab.

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

## Versions

Conveyor's protocol definitions come from Bazel 9.2 and are backwards compatible; builds
from Bazel 7 and 8 are exercised in CI (`.github/workflows/e2e.yml`).
