#!/usr/bin/env python3
"""Summarizes bench/overload.sh runs: bench/overload_report.py bench/results/overload-<label> ..."""
import json, sys, collections, os

def load(d):
    r = json.load(open(os.path.join(d, "loadgen.json")))
    phases = dict(l.split() for l in open(os.path.join(d, "phases")))
    on, off = int(phases["throttle_on"]), int(phases["throttle_off"])
    t0 = r["started_at_unix_ms"] / 1000
    series = collections.defaultdict(dict)  # (t, node) -> {series: value}
    for line in open(os.path.join(d, "metrics.tsv")):
        t, node, name, value = line.rstrip("\n").split("\t")
        series[(int(t), node)][name] = float(value)
    times = sorted({t for t, _ in series})
    nodes = sorted({n for _, n in series})

    def total(prefix, t):
        return sum(v for n in nodes for k, v in series.get((t, n), {}).items() if k.startswith(prefix))

    def worst(prefix, t):
        return max([v for n in nodes for k, v in series.get((t, n), {}).items() if k.startswith(prefix)] or [0])

    last = times[-1]
    refused = collections.Counter()
    for n in nodes:
        for k, v in series[(last, n)].items():
            if k.startswith("conveyor_admission_refused_count"):
                refused[k[k.index("{"):]] += int(v)

    # Server-side recovery: seconds after the throttle is lifted until the oldest waiting
    # batch is under 2 s on every node and stays there.
    after = [t for t in times if t >= off]
    recovered = None
    for t in after:
        if all(worst("conveyor_ingest_writer_backlog_oldest_ms", u) < 2000 for u in after if u >= t):
            recovered = t - off
            break

    # Client-side: builds by the 10 s window they ended in.
    def window(lo, hi):
        ok = failed = 0
        worst_ack = 0
        for w in r["timeline"]:
            end = t0 + w["t_s"]
            if lo <= end < hi:
                ok += w["ok"]; failed += w["failed"]; worst_ack = max(worst_ack, w["ack_max_ms"] or 0)
        return ok, failed, round(worst_ack / 1000, 1)

    clean = None
    for w in r["timeline"]:
        end = t0 + w["t_s"]
        rest = [x for x in r["timeline"] if t0 + x["t_s"] >= end]
        if end >= off and all(x["failed"] == 0 and (x["ack_max_ms"] or 0) < 5000 for x in rest):
            clean = round(end - off)
            break

    lat = r["ack_latency_ms"]
    rows_file = os.path.join(d, "rows")
    rows = dict(l.split()[1:3] for l in open(rows_file) if l.startswith("rows")) if os.path.exists(rows_file) else "not recorded"
    return {
        "run": open(os.path.join(d, "params")).read().strip(),
        "builds started": r["builds_total"],
        "builds completed": r["builds_ok"],
        "builds failed": r["builds_failed"],
        "failed, by answer": dict(r["failure_kinds"]),
        "completed builds that reconnected": r["retried_builds"],
        "reconnects (resends) of completed builds": r["resends"],
        "missing acks": r["missing_acks"],
        "ack p50 / p99 / max s (completed builds)": "%.1f / %.1f / %.1f" % tuple((lat[k] or 0) / 1000 for k in ("p50", "p99", "max")),
        "peak open streams (client)": r.get("peak_streams"),
        "generator start lag ms": r.get("max_start_lag_ms"),
        "healthy phase ok/failed/worst ack s": window(0, on),
        "throttled phase ok/failed/worst ack s": window(on, off),
        "recovery phase ok/failed/worst ack s": window(off, 1e12),
        "fenced commits": int(total("conveyor_ingest_fenced_count", last)),
        "expired batches": int(total("conveyor_ingest_writer_expired_count", last)),
        "group commit failures": {k[k.index("{"):]: int(v) for n in nodes for k, v in series[(last, n)].items() if k.startswith("conveyor_ingest_writer_group_failed_count")},
        "resent-event acks (server)": int(total("conveyor_ingest_ack_resent_count", last)),
        "refused (door, reason)": dict(refused),
        "peak oldest batch age s": round(max(worst("conveyor_ingest_writer_backlog_oldest_ms", t) for t in times) / 1000, 1),
        "peak admission level": int(max(worst("conveyor_admission_state_level", t) for t in times)),
        "peak open streams (servers)": int(max(total("conveyor_ingest_streams_count", t) for t in times)),
        "s until oldest batch < 2 s after the throttle is lifted": recovered,
        "s until the first clean 10 s window (no failure, acks < 5 s)": clean,
        "rows left": rows,
    }

for d in sys.argv[1:]:
    print("== " + d)
    for k, v in load(d).items():
        print("  %-62s %s" % (k, v))
