# Duplicate work

How much of what a fleet executed was a repeat of an action that another execution had
already finished, or was still running? The **Duplicate work** page of a project
(`/p/<slug>/duplicate-work`) and of a cache group (`/groups/<name>/duplicate-work`)
measures it in core time, by kind of action. The same numbers are JSON at
`/p/<slug>/duplicate-work/json`, `/groups/<name>/duplicate-work/json` (browser session)
and `GET /api/v1/duplicate-work?range=7d` (an API key with the `read` scope; its own
project). The page reports metrics and their definitions; it does not recommend a setup.

The feature was named "RBE opportunity" until 2026-11-23. Its old addresses still work:
`/p/<slug>/rbe` and `/groups/<name>/rbe` redirect (301, query string kept) to the pages
above, and `/p/<slug>/rbe/json`, `/groups/<name>/rbe/json` and `GET /api/v1/rbe` answer
the same body as the new paths. The JSON keys did not change.

## Setup: one line

```
# .bazelrc
build --build_event_publish_all_actions
```

That is the whole setup when the builds already send their events to Conveyor: Bazel
then sends one event per action, and the page is computed from them. It needs **Bazel
8.6 or later** (9.x included) for the action times; builds of an older Bazel are counted
and say so ("counted only"). Optionally name the commit, which makes duplicates between
builds of one commit exact:

```
bazel build --build_metadata=COMMIT_SHA=$(git rev-parse HEAD) //...
```

Conveyor reads the commit from the first of these tags (any letter case): `commit`,
`commit_sha`, `git_commit`, `build_scm_revision`, `stable_git_commit`; they come from
`--build_metadata`, a workspace status command (`BUILD_SCM_REVISION`) or an API key's
default tags. Uploading execution logs is an optional **exact mode**
([below](#exact-mode-execution-logs)); a build with a parsed log is reported from its
log.

### What the event stream gives, and how sure each figure is

An action is identified by its label, mnemonic, primary output and command line. At one
commit that identifies it exactly. Across commits it does not: an input that changed is
in no command line. So each class of duplicate has three figures:

| Figure | What it is | Standing |
|---|---|---|
| **same commit** | duplicates between builds that name the same commit | exact for identical inputs (equal to the execution logs, count for count, on every recorded scenario); misses duplicates across commits |
| **any commit** | every execution that repeats an action another build finished or was running, whatever the commit | an upper bound: every real duplicate is in it, and so is every action whose inputs changed without changing its command line |
| **estimate** | same commit, plus the share of the rest that is likely the same work | an estimate, always between the two; absent when the window has no evidence |

**The estimate.** A cache hit is sent with the times of the execution it was served
from, so Conveyor knows which builds read the results of which. Such a build shows what
changed between two commits: the actions it got from the cache were unchanged, the ones
it ran anyway were changed. The estimate counts, of the cross-commit repeats that
nothing else decides, the unchanged share per kind of action
(`unchanged ÷ (unchanged + changed)`, by count for counts and by time for times; over
all kinds where a kind has no observation). Repeats on a machine that had the earlier
result are counted as changed, not as duplicates. The page's "Across commits" tile shows
the share and what it rests on. Measured against execution logs of the same builds
(PLAN §28.4):

| scenario | truth | same commit | estimate | any commit |
|---|---|---|---|---|
| Go change, second commit on the machine that built the first | 0 | 0 | 0 | 4.7 s |
| a commit that changes nothing, then a cold machine | 62.0 s | 0 | 62.0 s | 62.0 s |
| C++ header change: cold, cold at the new commit, warm at the new commit | 512.3 s | 254.4 s | 509.9 s | 766.7 s |
| the same with the warm build before the cold one | 512.3 s | 254.4 s | 475.4 s (−7 %) | 766.7 s |
| C++ header change, two cold machines, no build that read a cache | 257.8 s | 0 | none | 512.3 s |

Limits, stated: without a build that reads another commit's results from a cache there
is no estimate; a build without a commit is in no same-commit figure; the stream cannot
tell a spawn that may not be cached from one that may, so such spawns count as
executions (execution logs leave them out; none in the recorded builds, so the
over-count is not measured); Bazel sends one event per action, so a retried or flaky
action is its final attempt only (not recorded, not verified). Cores are estimated: the
project's cores per mnemonic, else CPU time ÷ wall time of the kind in each build.
Actions without times (file writes, symlinks: not spawns) are not counted.

**The source line** at the top of the page says where its figures come from (the event
stream, execution logs, or both), how many finished builds sent per-action events, and
how many of those are counted only (Bazel before 8.6), name no commit, are pending
classification (done when a build ends; at the latest by a job that runs every 5
minutes) or arrived after their hour's figures were final (not counted). The stream
section then has the two headline classes with their three figures, three hit rates
(today; with a perfect cache; with in-flight deduplication; a range is same commit to
any commit), kinds of action and the targets that repeat the most. "Per day" divides by
the UTC days with at least one build reported from per-action events. JSON: `source`
and `stream` (`same_commit`, `estimate`, `any_commit`, `hit_rate`, `per_day`,
`mnemonics`, `targets`, `coverage`, and the build counts).

Records are kept for the project's "days per-spawn rows are kept" (default 3); the
hourly numbers and the keys stay, as for execution logs. An hour's stream figures are
final one hour before its records expire.

## Exact mode: execution logs

There are two reports from execution logs and the plain event stream on the page, and
every number says which one it belongs to.

| Standing | Source | What it can say |
|---|---|---|
| **exact wall · cores as stated** | execution logs (`--execution_log_compact_file`) | Which executions were duplicates of which, to the millisecond of the machines' clocks. Only for builds that uploaded a log. |
| **bound** | the build event stream every build already sends | How much executed and how much was served from a cache. It cannot tell a duplicate from necessary work: it is an upper bound. |

The coverage line at the top says how many finished builds of the window uploaded a log.
A duplicate can only be found between two builds that both did: logs from every build of
a pipeline show all of its duplicates, logs from a sample of builds only those among the
sample ([setup](bazel.md#duplicate-work-execution-logs-for-whole-pipelines)).

## Definitions

**Action key.** Executions are grouped by the remote-execution *action digest*, which the
compact execution log carries per spawn when Bazel runs with a remote cache, a disk cache
or a remote executor. Without any of those the field is empty and Conveyor computes its
own key from the command line, the environment, the platform properties, the declared
outputs and every input path with its content digest. Two executions with one key are one
cache entry. The fallback key is as fine as Bazel's as long as the fleet runs one Bazel
configuration. A log with a digest and a log without never match each other, so a project
whose builds mix the two has duplicates the page does not find. The coverage line says how
many executions used the fallback.

**Scope.** Keys are compared inside a project, and inside its *cache group* when it has
one: a set of projects whose executions are compared with each other, such as the
projects of one codebase (a monorepo with a project per app). A global admin sets the group in the page's settings. A project that
joins a group contributes the logs parsed from then on.

**Classes.** For each key in a scope, the execution that *finished first* is `first`.
Every other execution is a duplicate:

- **sequential**: it started after the first one had finished. The result existed when
  it started. A cache shared by the machines involved serves such a result.
    - *within the project*: an execution of its own project had finished it;
    - *across projects*: only an execution of another project of the group had.
- **racing**: it started while the first one was still running. No result existed yet,
  so a cache has nothing to serve. An executor that merges identical actions in flight
  (remote build execution, RBE) runs such an action once. Racing executions that may not
  run remotely (`no-remote`) are shown apart and left out of the headline.

Cache hits are not executions. Failed executions, and executions that may not be cached
(`no-cache`, `no-remote-cache`), take part in nothing: they are listed as outside any
cache.

**Duplicate time** is the execution wall time of every duplicate: total executed time minus
the time of each key's first finisher.

**Core time** is wall time × cores of the action. Wall time is measured by Bazel. The
cores come from, best first:

1. **exec property**: a platform property of the spawn with one of the names the
   project declares ([below](#declaring-cores-per-action)); built in: `cpu`, `cpus`,
   `cores`, `num-cpus`, `num_cpus`, `EstimatedCPU`, `resources:cpu`. Per action, exact,
   never overridden. This is the only place the compact execution log states cores: it
   has no field for execution requirements, so a `cpu:4` tag or a test size does not
   reach it. With `exec_properties = {"cores": "4"}` on the target (or on the execution
   platform) the core time of its actions is exact;
2. **project setting**: `Mnemonic=cores` in the page's settings (`TestRunner=4`);
3. **target tag**: the `cpu:N` tag of a test target, from the event stream
   (test runner spawns);
4. **measured**: CPU time of the mnemonic in the build (`BuildMetrics`) ÷ its wall time
   in the log, at least 1;
5. **default**: 1.

The table by kind of action shows the average cores used and where they came from. The
line above it says how much of what executed states its own cores: the share of executed
wall time, and of executions, whose cores came from the exec property, and what the rest
fell back to (`cores_coverage` in the JSON; per mnemonic `exact_share`). Counts per
source exist for hours summarized since this was added; a window that still holds an
older hour shows wall time only.

## Declaring cores per action

A project says how its builds declare cores on RBE in the page's settings ("How this
project declares cores per action"; a project admin, audited as `project.rbe_settings`):

- **Exec property names, in order.** Up to 8 names, comma separated; letters, digits and
  `. _ : / -`, up to 64 characters each. For each spawn the names are tried in this
  order and the first one the spawn carries *with a readable value* wins (a name present
  with a value that is not a number in range is passed over). Names match in any case
  (`Cores` = `cores`). Blank restores the built-in list. A name outside the list is not
  read, built-in or not.
- **Unit.** `cores`: `4`, `0.5` (up to 1024). `millicores`: `4000` (up to 1,024,000).
  `auto` (default): a plain number is cores. Under every unit a value ending in `m`
  (`4000m`) is millicores.

The default (the built-in names, `auto`) is what Conveyor did before the setting existed,
with one difference: when a spawn carries two of the built-in names with different
values, the list's order now decides, not the order of the properties in the log.

**Which name do my builds use?** The settings panel lists the property names seen in the
project's parsed logs, with the number of spawns that carried each in the last log that
had it and an example value. Only a project admin sees the list; it is not in the JSON.
It holds at most 100 names per project (50 per log), no per-spawn data, and an example
only when the value is short and plain (`[A-Za-z0-9_.:/+-]`, 40 characters) and neither
name nor value looks like a credential (`token`, `secret`, `key`, `auth`, a URL…). A
name is refreshed at most every ten minutes. Logs parsed before this version are not in
it until one is parsed again.

**Logs already parsed.** The property is read when a log is parsed and the result is
stored per action as the exact source; the platform properties themselves are not
stored. A changed declaration therefore applies to logs parsed afterwards. To apply it
to earlier builds, use **Re-read cores from stored logs (N builds)** next to the
settings: it parses the stored execution log of the builds in the page's window again
(the 200 most recent that are parsed and still have their log attached; widen the range
and repeat for more), in the background, behind new uploads, audited as
`project.rbe_reread`. Parsing the same log again changes the cores and nothing else:
keys, classes and counts stay (PLAN §27.3). Builds whose spawns passed retention
(`expired`) are not re-read and keep their summarized numbers. Each re-parse costs what
the first parse did (about 6 s for a 50,000-spawn log).

How to set the property in Bazel: [Bazel setup](bazel.md#declaring-cores-with-exec_properties).

## The headline numbers

| Tile | Formula | What it measures |
|---|---|---|
| **Sequential duplicates** | core time of sequential duplicates ÷ logged days of the window | "Executed although the same action had already finished elsewhere." Split into within the project, across projects, and the part on a host's first three builds (cold machines). |
| **Cache hit rate** | three values, by count of spawns ([below](#the-three-hit-rates)). By time: sequential wall time ÷ executed wall time | The log has no time for a hit (nothing ran), so the time rate is the share of *executed* time that repeated a finished result. |
| **Racing duplicates** | core time of racing duplicates that may run remotely ÷ logged days | "Executed while the same action was still running elsewhere." |
| **Cold machines** | sequential duplicates of builds that are among the first three of their host | The part of the sequential duplicates executed on machines that had run at most two builds before. When it equals the sequential duplicates (machines that live for one to three builds) the tile is not shown: the row inside the first tile says "all of it". The JSON always has `cache.cold`. |
| **Outside any cache** | core time of executions that are not cacheable or failed; time that may not run remotely | Executions that take part in no class: no cache stores their result. |
| **Parallelism headroom** | Σ action wall time ÷ Σ critical path (bound), ÷ Σ execution phase (achieved) | The most cores a build could keep busy against what it used. A bound: the critical path assumes unlimited cores. The host's core count is not in either data source. |

The two first tiles are the page's headline metrics and are shown large, each with a
help line that states which mechanism addresses its class (the sentences under
[Classes](#definitions)). They are per logged day, with the window's total
under them. Tables show totals of the window. The four small tiles carry the short
standing "exact"; its long form ("exact wall · cores as stated") is on the two headline
tiles and in the legend line.

### Per logged day

A **logged day** is a UTC day in which at least one build *started* whose execution log
was parsed. Every per-day figure of both pages is the window's total ÷ the window's
logged days, and each headline tile says "N of M days have logs (UTC days the window touches)", M being the UTC days
the window touches (a 7-day window that starts and ends at noon touches 8). A project
that enabled logs yesterday therefore shows the same daily figure in the 24h and the 7d
view. With no logged day there is no per-day figure. One approximation: the window's
last two hours are summarized as one bucket, so builds of both sides of a midnight that
falls inside it count as one day. In the JSON: `logged_days`, `window_days`,
`per_logged_day.{sequential,racing,cold}` (each `n`, `ms`, `core_ms`; null without a
logged day) beside the totals (`cache.gap`, `racing.remotable`, `cache.cold`); `days`
is still the window's length.

### The three hit rates

All three are shares of the window's spawns in parsed logs (cache hits + executions), by
count. In the JSON they are `cache.hit_rate`.

| Name | JSON key | Formula | Meaning |
|---|---|---|---|
| **today** | `today` | hits ÷ spawns | Served from cache. |
| **perfect cache** | `perfect_cache` | (hits + sequential duplicates) ÷ spawns | If every finished result were shared: an execution that started after the same action had finished would have been a hit. |
| **with in-flight deduplication** | `with_in_flight_deduplication` | (hits + sequential + racing duplicates that may run remotely) ÷ spawns | Also merging identical actions that were still running. It is the largest of the three by construction. |

`cache.actual_rate`, `cache.ideal_rate` and `cache.rbe_rate` are the same three values
under their first names, kept for one release.

**Projects of the group** (a group's page, and a member's): one row per project the viewer
may see, with what it repeated (racing, after itself, after another project) and after
whom. Found by name, sorted by any column, 25 per page; the footer sums what the search
found. Projects the viewer may not see are one row without names.

**The CI recipe.** The empty state and the settings panel show what a CI job adds to
upload its log (`build:ci --execution_log_compact_file`, an `--invocation_id` the job
chooses, a `PUT` to `/api/v1/invocations/<id>/artifacts/execution.log.zst` with
`x-api-key` and `content-type: application/octet-stream`), with the address the page was
reached at. The key in it is a placeholder. The flag does not change cache keys (Bazel
9.2, checked 2026-11-22: a build without it hit every action cached by a build with it,
and toggling it did not discard the analysis cache).

Other panels: duplicates per target, per project of the group (with whose finished work
each project repeated), racing per pipeline (set the pipeline tag key in the settings; racing executions that may not run remotely are left out, as in the headline, so the panel sums to it when every build carries the tag),
near misses (one output of one target at one commit under two keys: inputs differ where
they should not; the input diff is on the builds' Actions tab) and actions whose outputs
differ between executions of one key (not deterministic).

## Clocks

Starts and finishes are taken by the machines that ran the actions. With clocks a few
seconds apart, an execution that started close to the first one's finish could belong to
either class. The racing tile reports how many racing and how many sequential executions
lie within the project's tolerance (1 to 60 s, default 2): racing is between
*racing − uncertain racing* and *racing + uncertain sequential*. The band is as wide as
the hosts' clocks disagree; hosts synchronized by NTP agree within milliseconds.

## Two fleet shapes and what the numbers show

**Shards with one central cache (for example iOS shards of one pipeline).** Every shard
reads and writes the same cache, so an action that has finished anywhere is a cache hit
for the others and sequential duplicates are few. Shards of one pipeline start together
and execute the same actions before any of them has uploaded a result: those executions
are racing duplicates. *Racing by pipeline* shows how the racing core time is spread
over pipeline runs. Where sequential duplicates do appear with a shared cache, the
executions ran under different action keys or the result was not in the cache; near
misses and actions that are not deterministic are the two causes of differing keys the
page counts.

**A cache per machine (for example a Go monorepo with a project per app, in one cache
group).** A machine's cache holds only what that machine built, so an action another app
or another machine has finished executes again: a sequential duplicate. *Across
projects* is the part first finished by another project of the group, *cold machines*
the part executed in a host's first three builds. Racing duplicates are the executions
that overlapped in time with the first one; a cache shared by the machines would not
have held their result when they started.

## What the numbers do not measure

- Build minutes. Duplicate core time is time of actions; a build is shorter without
  them only where those actions were on its critical path and cores were the constraint.
- Builds without a log. The numbers describe the builds that uploaded one.
- Other effects of remote execution: more parallelism than a CI machine has, queueing,
  network transfer of inputs and outputs. The parallelism tile is a bound from the
  critical path, not a measurement of any executor.
- A recommendation. Which class a duplicate is in, and which mechanism addresses that
  class, are stated as definitions; whether to adopt a shared cache or remote execution
  depends on costs this page does not have.

## Exactness

Under these conditions duplicate wall time is exact: the builds compared uploaded complete
logs; their action keys come from one source; machine clocks agree within the tolerance.
Logs may arrive in any order and be parsed at the same time: the first execution of a key
is decided by the actions' own timestamps, never by arrival, and hours already summarized
are computed again when a later log changes a class (`docs/spec/ActionKeys.tla`).
Keys are forgotten two days after the execution-log retention of the project
(`RETENTION_SPAWN_DAYS`, 30): a key not executed for that long starts over, as it would in
a cache that evicted it.

## Data and cost

Measured with 360 projects in one cache group and 2,000 builds of 1,668 spawns on
average (PLAN §27.9, `bench/rbe_scale.sh`): per spawn about 820 bytes in `spawns`
(heap and indexes; the analysis' own share is about 150), about 480 bytes of input
lists, about 80 bytes of action keys (a key is one row in its project and one in its
group) and 3.2 KB of write-ahead log. A node parses about 12,700 spawns per second with
its two parse jobs (460 logs of that size per minute), two nodes 1.74 times that, without
lock waits. A 3,500-spawn log therefore costs about 4.8 MB of database until its spawns
expire (`RETENTION_SPAWN_DAYS`, 30) and 0.5 s of one parse worker; 360 apps at 50 builds
a day are 87 GB a day. The hourly numbers of the page survive the expiry, so the spawn
retention bounds the database size without changing the page.

## Per-action events in the event stream

`build --build_event_publish_all_actions` makes Bazel send an event for every action
(about 2 KB each, most of it the command line). Conveyor keeps of each successful one a
record of about 12 to 24 bytes (key, times, kind, target) and nothing else: no row on a
build's Actions tab, and the event, with the empty progress event Bazel sends behind it,
is counted but not stored with the build's raw events (on recorded builds these are 77
to 92 % of a stream's events and 84 to 170 stored bytes per action). The build's Events
tab says how many events were received and not stored. **Keep per-action events in the
raw event stream** in the settings stores them for builds that start afterwards. Failed
actions are always stored and listed.

Cost, measured on a laptop with the recorded builds replayed at once (PLAN §28.5,
`bench/run.sh --profile stream`, `bench/stream_scale.sh`): a node takes about 38,000
actions per second flat out (29,000 with 60 projects, API keys and the key merges
running beside the ingest). An action, with the progress event behind it, costs about
80 µs of node CPU, 6 µs of Postgres CPU and about 100 bytes of write-ahead log; its
record is 15 bytes (29 with the table's overhead). A build of 3,500 actions therefore
costs about 0.3 s of one core, 0.4 MB of write-ahead log and 50 to 100 KB of records,
which are deleted after the "days per-spawn rows are kept". Its keys are merged when it
ends (11 ms at the median, 38 ms at the 99th percentile for the recorded builds of 248
to 1,357 actions) by a job on the `parse` queue.

Keys are the larger part of what stays: a key row is about 220 bytes with its index.
There is one row per action and scope that lives as long as keys do (the any-commit
row, shared by every build that runs the action), and one per action, commit and scope
(the same-commit row). In the scale run the same-commit rows were 71 % of the key
table, so they are deleted two days after the records of their builds (5 days by
default) instead of with the other keys (32 days): a build of that commit that arrives
later starts over in the same-commit figure. Builds without the flag are not affected:
they write the same write-ahead log per event as before (617 bytes in the standard
bench, before and after).

## Keeping only what the metrics need

A project admin can turn on **Keep only what the duplicate-work metrics need** in the
page's settings (Storage; off by default; audited with the other settings as
`project.rbe_settings`). It is for projects that upload logs for these numbers and not
for the per-build Actions tab. With it on, for logs parsed from then on:

| | Default | Analysis only |
|---|---|---|
| Input list per spawn (`spawn_inputs`) | stored, shared per project | **not stored**. The input digest of every spawn still is: the fallback action key and the non-determinism check read it. |
| Output list per spawn (`spawns.outputs`) | stored | **not stored** (the outputs digest and the primary output are) |
| The uploaded log (artifact and its bytes) | kept with the build | **deleted once parsed** (bytes another build still references stay) |
| Per-spawn rows (`spawns`) | execution-log retention (`RETENTION_SPAWN_DAYS`, 30) | **"Days per-spawn rows are kept"**: 1 to 30, default 3, never longer than the execution-log retention |
| Action keys (`action_keys`) | execution-log retention + 2 days | the same: a build is still matched against a first execution whose rows are gone |
| Hourly numbers of this page | build retention | the same |

What it gives up:

- **Which inputs changed.** The Actions tab of a build ("Why did it run?") still lists
  the spawns and says whether an action's inputs changed, and states that input lists
  are not kept for the project; the list of added, removed and changed inputs is not
  available. After the row days the tab shows the log as expired.
- **Re-reading cores from stored logs.** There is no stored log: the button is disabled
  and says why. A changed cores declaration applies to logs parsed afterwards.
- **Uploading a different log for a build after the row days** rebuilds its keys from
  the rows that remain (as with the default retention, only sooner).

**The freeze rule.** An hour's numbers are computed from the spawn rows of its builds.
Rows expire with their build: retention (daily) deletes the rows of builds that started
more than the row days ago. An hour is therefore **frozen one hour before its first
build can expire** (at *start of the hour + row days − 1 hour*), and also whenever one of
its builds is marked expired: from then on it keeps what its last summary holds and is
never computed from part of its rows. Hours of such a project are summarized every five
minutes over the whole row window, so a log parsed at least five minutes before the
freeze is in the numbers.

**What that costs in exactness.** Numbers are exact for the logs parsed before their
hour froze. A log parsed later (a *late log*):

- is merged into the action keys, so builds of hours that are not frozen are classed
  against it correctly;
- is itself in no number: its executions, hits and coverage are not counted;
- cannot change a frozen hour: an execution there that it shows to be a duplicate (the
  late log's execution finished earlier) keeps the class it had, `first` included.

So duplicate time is under-counted by at most the executed time of the late logs plus,
for each action key whose first execution a late log takes over, the time of one
execution. The settings panel shows how many logs arrived late since the mode was turned
on. The same rule holds for every project at its execution-log retention; this mode
moves it from 30 days to the row days. Choose the days to cover the longest delay
between a build's start and the upload of its log, of any shard or project of the
group.

**In a cache group** the mode is per project and members may differ. The group's keys
are kept by the longest execution-log retention among its members, whatever their
modes. Each member's hours freeze by its own days, and the group's page sums its
members' hours: a late log of any member is matched by every member's later builds; an
execution of an analysis-only member in a frozen hour keeps its class, while the same
execution in a member that keeps rows for 30 days is classed again. Input lists were
per project already, so one member's mode does not affect another's Actions tab.

**Measured** (60 projects in one group, 600 builds, 909,008 spawns; PLAN §27.11):

| per build (1,515 spawns) | default | analysis only | |
|---|---|---|---|
| `spawns` (heap + indexes) | 1,243 KB (820 B per spawn) | 921 KB (608 B per spawn) | 1.35× |
| `spawn_inputs` | 1,061 KB as written (196 KB after `VACUUM FULL`) | 0 | |
| `action_keys` | 82 KB | 83 KB | 1× |
| uploaded log (blob store) | 1,312 KB, kept with the build | 0 once parsed | |
| write-ahead log | 3.50 MB | 1.61 MB | 2.2× |
| stored while the rows live (tables + log) | 3.70 MB | 1.00 MB | 3.7× |
| parse job, p50 / p99 | 159 / 699 ms | 141 / 616 ms | |
| logs per minute, one node | 527 | 606 | |
| after the row retention has passed | rows stay 30 days | `spawns` 0, `spawn_inputs` 0; 71 KB of keys and 10 KB of hourly rows remain | |
| exactness, before and after retention | 30 of 30 figures, group 5 of 5 | 30 of 30, group 5 of 5 | |

Steady state per build a day, from these figures (computed, not run for 30 days; rows
of the default for 30 days, of the mode for up to 4 because retention runs daily, keys
32 days, hourly rows and the default's uploaded logs for the 90 days of build
retention): database 44 MB against 6.8 MB, **6.5 times** less with compacted tables
(72 MB against 6.8 MB, 10.6 times, with `spawn_inputs` as written); database and
uploaded logs together 162 MB against 6.8 MB, **24 times** less. The whole bench
database after the retention job with the clock moved four days and `VACUUM FULL`:
884 MB (nothing expired) against 62 MB.

Turning the mode off applies to logs parsed afterwards; rows, lists and logs that were
not kept do not come back, and the hours whose rows expired stay frozen.

A cache group's page reads stored hours only: its window starts at the top of the hour
(a "24h" view covers up to 24 h 59 min) and hours whose builds changed are summarized
again first, four projects at a time. With 360 projects it answers in under a second
when the hours are current and in about 12 s when all 1,400 of them have to be
summarized.

Tenancy: a
project's numbers are visible to whoever may see the project; a group's totals to whoever
may see one of its projects, with the other projects summed without names or targets.
