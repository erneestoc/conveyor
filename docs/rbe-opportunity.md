# RBE opportunity

Would a shared cache, or remote build execution (RBE), save work for this fleet, and how
much? The **RBE opportunity** page of a project (`/p/<slug>/rbe`) and of a cache group
(`/groups/<name>/rbe`) answers in core time, by kind of action. The same numbers are JSON
at `/p/<slug>/rbe/json`, `/groups/<name>/rbe/json` (browser session) and
`GET /api/v1/rbe?range=7d` (an API key with the `read` scope; its own project).

There are two reports on the page, and every number says which one it belongs to.

| Standing | Source | What it can say |
|---|---|---|
| **exact wall · cores as stated** | execution logs (`--execution_log_compact_file`) | Which executions were duplicates of which, to the millisecond of the machines' clocks. Only for builds that uploaded a log. |
| **bound** | the build event stream every build already sends | How much executed and how much was served from a cache. It cannot tell a duplicate from necessary work: it is an upper bound. |

The coverage line at the top says how many finished builds of the window uploaded a log.
A duplicate can only be found between two builds that both did, so enable logs for whole
pipelines, not for a sample of builds ([how](bazel.md#rbe-opportunity-execution-logs-for-whole-pipelines)).

## Definitions

**Action key.** Executions are grouped by the remote-execution *action digest*, which the
compact execution log carries per spawn when Bazel runs with a remote cache, a disk cache
or a remote executor. Without any of those the field is empty and Conveyor computes its
own key from the command line, the environment, the platform properties, the declared
outputs and every input path with its content digest. Two executions with one key are one
cache entry. The fallback key is as fine as Bazel's as long as the fleet runs one Bazel
configuration; logs with a digest and logs without never match each other, so keep a
project uniform. The coverage line says how many executions used the fallback.

**Scope.** Keys are compared inside a project, and inside its *cache group* when it has
one: projects that build one codebase and should share one cache (a monorepo with a
project per app). A global admin sets the group in the page's settings. A project that
joins a group contributes the logs parsed from then on.

**Classes.** For each key in a scope, the execution that *finished first* is `first`.
Every other execution is a duplicate:

- **sequential**: it started after the first one had finished. The result existed; a
  shared cache would have served it. *RBE is not required for this.*
    - *within the project*: an execution of its own project had finished it;
    - *across projects*: only another project of the group had. This is the per-machine
      or per-app cache case: work somebody else already did.
- **racing**: it started while the first one was still running. No cache has the result
  yet; only an executor that deduplicates actions in flight saves it. *Only RBE recovers
  this.* Racing executions that may not run remotely (`no-remote`) are shown apart and
  left out of the headline.

Cache hits are not executions. Failed executions, and executions that may not be cached
(`no-cache`, `no-remote-cache`), take part in nothing: they are listed as outside any
cache.

**Wasted time** is the execution wall time of every duplicate: total executed time minus
the time of each key's first finisher.

**Core time** is wall time × cores of the action. Wall time is measured by Bazel. The
cores come from, best first:

1. **exec property**: a platform property of the spawn with one of the names the
   project declares ([below](#declaring-cores-per-action)); built in: `cpu`, `cpus`,
   `cores`, `num-cpus`, `num_cpus`, `EstimatedCPU`, `resources:cpu`. Per action, exact,
   never overridden. This is the only place the compact execution log states cores: it
   has no field for execution requirements, so a `cpu:4` tag or a test size does not
   reach it. Set `exec_properties = {"cores": "4"}` on the target (or on the execution
   platform) to make core time exact;
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

| Tile | Formula | Read it as |
|---|---|---|
| **Cache opportunity** | core time of sequential duplicates ÷ days of the window | What a cache shared by every machine recovers. Split into within the project, across projects, and the part on a host's first three builds (cold machines). |
| **Hit rate, actual → ideal** | actual = hits ÷ spawns; ideal = (hits + sequential) ÷ spawns; with RBE also + racing. By time: sequential wall time ÷ executed wall time | The log has no time for a hit (nothing ran), so the time rate is the share of *executed* time that should have been a hit. |
| **Racing duplicates** | core time of racing duplicates that may run remotely ÷ days | The increment RBE adds over a perfect shared cache. |
| **Cold machines** | sequential duplicates of builds that are among the first three of their host | The cost of machines that start with an empty cache. |
| **Outside any cache** | core time of executions that are not cacheable or failed; time that may not run remotely | What neither a cache nor RBE touches. |
| **Parallelism headroom** | Σ action wall time ÷ Σ critical path (bound), ÷ Σ execution phase (achieved) | The most cores a build could keep busy against what it used. A bound: the critical path assumes unlimited cores. The host's core count is not in either data source. |

The two first tiles are the page's answers and are shown large, per day (the window's
core time ÷ the window's days, whether or not a day had logs), with the window's total
under them. Tables show totals of the window.

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
each project repeated), racing per pipeline (set the pipeline tag key in the settings),
near misses (one output of one target at one commit under two keys: inputs differ where
they should not; the input diff is on the builds' Actions tab) and actions whose outputs
differ between executions of one key (not deterministic).

## Clocks

Starts and finishes are taken by the machines that ran the actions. With clocks a few
seconds apart, an execution that started close to the first one's finish could belong to
either class. The racing tile reports how many racing and how many sequential executions
lie within the project's tolerance (1 to 60 s, default 2): racing is between
*racing − uncertain racing* and *racing + uncertain sequential*. Keep CI hosts on NTP.

## Reading the two common cases

**Shards with one central cache (iOS).** Sequential duplicates should be near zero: the
cache works. The question is racing: shards of one pipeline start together and build the
same actions before any of them has uploaded a result. *Racing duplicates* is the core
time RBE would save; *Racing by pipeline* shows whether it is every run or a few. If
sequential duplicates are high instead, fix the cache first (near misses and
non-deterministic actions say why keys differ).

**A cache per machine (a Go monorepo, an app per project).** Put the projects into one
cache group. Read the cache opportunity first: *across projects* is the work another app
had already finished, *cold machines* the part paid by fresh hosts. That is what a shared
cache recovers without RBE. Racing is the increment on top; decide on RBE from that
number and from the parallelism headroom, not from the total.

## What this is not

- Not build minutes. Core time saved shortens builds only where those actions were on the
  critical path and cores were the constraint.
- Not a statement about builds without a log.
- Not a bound on RBE's other effects (more parallelism than a CI machine has, queueing,
  network transfer of inputs and outputs).

## Exactness

Under these conditions wasted wall time is exact: the builds compared uploaded complete
logs; their action keys come from one source; machine clocks agree within the tolerance.
Logs may arrive in any order and be parsed at the same time: the first execution of a key
is decided by the actions' own timestamps, never by arrival, and hours already summarized
are computed again when a later log changes a class (`docs/spec/ActionKeys.tla`).
Keys are forgotten two days after the execution-log retention of the project
(`RETENTION_SPAWN_DAYS`, 30): a key not executed for that long starts over, as it would in
a cache that evicted it.

## Data and cost

Per executed spawn the analysis adds about 150 bytes to its row and index; per distinct
action key about 230 bytes (twice for a project in a cache group). Parsing a 50,000-spawn
log takes about 1.6 times what it took before (measurements in PLAN §27). Tenancy: a
project's numbers are visible to whoever may see the project; a group's totals to whoever
may see one of its projects, with the other projects summed without names or targets.
