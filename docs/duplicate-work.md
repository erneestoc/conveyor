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

There are two reports on the page, and every number says which one it belongs to.

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
logged days, and each headline tile says "N of M days have logs", M being the UTC days
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

A cache group's page reads stored hours only: its window starts at the top of the hour
(a "24h" view covers up to 24 h 59 min) and hours whose builds changed are summarized
again first, four projects at a time. With 360 projects it answers in under a second
when the hours are current and in about 12 s when all 1,400 of them have to be
summarized.

Tenancy: a
project's numbers are visible to whoever may see the project; a group's totals to whoever
may see one of its projects, with the other projects summed without names or targets.
