// Web Worker: fetches a Bazel JSON profile (served with Content-Encoding: gzip, so the
// browser inflates it), parses the trace events and hands the main thread compact typed
// arrays: one lane per thread, events sorted by lane then start time, nesting depth and
// parent links, interned strings, and a per-action breakdown into phases (cache check,
// upload inputs, queued, remote execution, download outputs, local execution, setup,
// outputs) attributed from the events nested inside each "action processing" span.
if (typeof self !== "undefined" && typeof window === "undefined") self.onmessage = async ({data}) => {
  try {
    const res = await fetch(data.url, {credentials: "same-origin"})
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = JSON.parse(await res.text())
    const built = build(json.traceEvents || [])
    const transfer = TYPED.map(k => built[k].buffer)
    self.postMessage({ok: true, ...built, otherData: json.otherData || {}}, transfer)
  } catch (e) {
    self.postMessage({ok: false, error: String(e && e.message ? e.message : e)})
  }
}

const TYPED = ["ts", "dur", "lane", "name", "cat", "arg", "mnemonic", "target", "depth", "parent", "phase", "actionOf", "laneOffsets", "laneMaxDur", "laneDepth", "actionEvent", "actionPhases", "phaseTotals"]

export const PHASES = ["other", "cache check", "upload inputs", "queued", "remote execution", "download outputs", "local execution", "setup", "outputs"]
export const PHASE_COLORS = ["#94a3b8", "#0ea5e9", "#f59e0b", "#a3a3a3", "#8b5cf6", "#14b8a6", "#10b981", "#f97316", "#64748b"]
const NP = PHASES.length
const ACTION_CAT = "action processing"

// Which phase of an action an event represents, from Bazel's profiler categories and the
// event names the remote and local spawn runners emit.
export function classify(cat, name) {
  const c = (cat || "").toLowerCase(), n = (name || "").toLowerCase()
  if (c === ACTION_CAT) return 0
  if (c.includes("cache check") || n.includes("check cache hit") || c === "remote action cache check") return 1
  if (c.includes("upload") || n.includes("upload")) return 2
  if (c.includes("queuing") || c.includes("queue") || n.includes("queued")) return 3
  if (c === "remote action execution" || n.includes("execute remotely") || c === "remote execution") return 4
  if (c.includes("download") || n.includes("download")) return 5
  if (c === "local action execution" || c === "local execution in worker" || n.includes("subprocess.run") || n.includes("worker working")) return 6
  if (c.includes("sandbox") || c.includes("staging") || c.includes("setup") || c.includes("local parse") || c.includes("worker borrow") || c.includes("worker setup") || c.includes("action fs")) return 7
  if (c === "complete action execution" || c.includes("worker copying outputs")) return 8
  return 0
}

export function build(events) {
  const threadName = new Map()
  const threadSort = new Map()
  const xs = []
  const counters = new Map()
  const markers = []
  const names = [], nameIdx = new Map()
  const cats = [], catIdx = new Map()
  const args = [], argIdx = new Map()
  const mnemonics = [], mnemonicIdx = new Map()
  const targets = [], targetIdx = new Map()
  const intern = (list, map, s) => {
    let i = map.get(s)
    if (i === undefined) { i = list.length; list.push(s); map.set(s, i) }
    return i
  }
  let minTs = Infinity, maxTs = -Infinity

  for (const e of events) {
    const key = `${e.pid}:${e.tid}`
    if (e.ph === "M") {
      if (e.name === "thread_name") threadName.set(key, (e.args && e.args.name) || key)
      else if (e.name === "thread_sort_index") threadSort.set(key, (e.args && e.args.sort_index) || 0)
      continue
    }
    if (e.ph === "X") {
      const ts = +e.ts || 0, dur = +e.dur || 0
      if (ts < minTs) minTs = ts
      if (ts + dur > maxTs) maxTs = ts + dur
      let a = -1, m = -1, t = -1
      if (e.args) {
        const parts = []
        for (const k of ["target", "mnemonic", "out", "name"]) if (e.args[k] != null) parts.push(`${k}=${e.args[k]}`)
        if (parts.length) a = intern(args, argIdx, parts.join("  "))
        if (e.args.mnemonic != null) m = intern(mnemonics, mnemonicIdx, String(e.args.mnemonic))
        if (e.args.target != null) t = intern(targets, targetIdx, String(e.args.target))
      }
      const c = intern(cats, catIdx, e.cat || "")
      xs.push({key, ts, dur, n: intern(names, nameIdx, e.name || ""), c, a, m, t, p: classify(e.cat, e.name)})
      continue
    }
    if (e.ph === "i" && e.cat === "build phase marker") { markers.push({name: e.name, ts: +e.ts || 0}); continue }
    if (e.ph === "C" && e.args) {
      let c = counters.get(e.name)
      if (!c) { c = {name: e.name, ts: [], series: {}}; counters.set(e.name, c) }
      c.ts.push(+e.ts || 0)
      for (const [k, v] of Object.entries(e.args)) {
        if (typeof v !== "number") continue
        if (!c.series[k]) c.series[k] = new Array(c.ts.length - 1).fill(0)
        c.series[k].push(v)
      }
      for (const k of Object.keys(c.series)) if (c.series[k].length < c.ts.length) c.series[k].push(0)
    }
  }
  if (!isFinite(minTs)) { minTs = 0; maxTs = 0 }

  // Lanes: every thread that has events, ordered by sort index then name.
  const laneKeys = [...new Set(xs.map(x => x.key))]
  laneKeys.sort((a, b) => {
    const sa = threadSort.has(a) ? threadSort.get(a) : 1e9, sb = threadSort.has(b) ? threadSort.get(b) : 1e9
    if (sa !== sb) return sa - sb
    return (threadName.get(a) || a).localeCompare(threadName.get(b) || b, undefined, {numeric: true})
  })
  const laneOf = new Map(laneKeys.map((k, i) => [k, i]))
  const threads = laneKeys.map(k => ({key: k, name: threadName.get(k) || k}))

  // Parents must precede children: by lane, then start, then longer first.
  xs.sort((a, b) => (laneOf.get(a.key) - laneOf.get(b.key)) || (a.ts - b.ts) || (b.dur - a.dur))
  const n = xs.length
  const ts = new Float64Array(n), dur = new Float64Array(n)
  const lane = new Int32Array(n), name = new Int32Array(n), cat = new Int32Array(n), arg = new Int32Array(n)
  const mnemonic = new Int32Array(n), target = new Int32Array(n)
  const depth = new Int32Array(n), parent = new Int32Array(n), phase = new Int8Array(n), actionOf = new Int32Array(n)
  const laneOffsets = new Int32Array(laneKeys.length + 1)
  const laneMaxDur = new Float64Array(laneKeys.length)
  const laneDepth = new Int32Array(laneKeys.length)
  const actionCat = catIdx.has(ACTION_CAT) ? catIdx.get(ACTION_CAT) : -1
  const actionEvents = [], actionPhaseRows = []
  const phaseTotals = new Float64Array(NP)
  const byMnemonic = new Map()
  const stack = [] // {i, end, action, classified}
  let currentLane = -1

  for (let i = 0; i < n; i++) {
    const x = xs[i], l = laneOf.get(x.key)
    ts[i] = x.ts; dur[i] = x.dur; lane[i] = l; name[i] = x.n; cat[i] = x.c; arg[i] = x.a
    mnemonic[i] = x.m; target[i] = x.t; phase[i] = x.p
    laneOffsets[l + 1] = i + 1
    if (x.dur > laneMaxDur[l]) laneMaxDur[l] = x.dur
    if (l !== currentLane) { stack.length = 0; currentLane = l }
    while (stack.length && x.ts >= stack[stack.length - 1].end - 1e-9) stack.pop()
    const top = stack.length ? stack[stack.length - 1] : null
    parent[i] = top ? top.i : -1
    depth[i] = stack.length
    if (stack.length + 1 > laneDepth[l]) laneDepth[l] = stack.length + 1
    let action = top ? top.action : -1, classified = top ? top.classified : false
    if (x.c === actionCat) {
      action = actionEvents.length
      actionEvents.push(i)
      actionPhaseRows.push(new Float64Array(NP))
      classified = false
    } else if (action >= 0 && x.p !== 0 && !classified) {
      actionPhaseRows[action][x.p] += x.dur
      classified = true
    }
    actionOf[i] = action
    stack.push({i, end: x.ts + x.dur, action, classified})
  }

  // "other" is the action's own time not covered by a classified phase; totals by phase
  // and by mnemonic feed the breakdown panel.
  const actionPhases = new Float64Array(actionEvents.length * NP)
  for (let a = 0; a < actionEvents.length; a++) {
    const row = actionPhaseRows[a]
    let covered = 0
    for (let p = 1; p < NP; p++) covered += row[p]
    row[0] = Math.max(dur[actionEvents[a]] - covered, 0)
    actionPhases.set(row, a * NP)
    for (let p = 0; p < NP; p++) phaseTotals[p] += row[p]
    const m = mnemonic[actionEvents[a]]
    const key = m >= 0 ? mnemonics[m] : "(no mnemonic)"
    let agg = byMnemonic.get(key)
    if (!agg) { agg = {name: key, count: 0, total: 0, phases: new Array(NP).fill(0)}; byMnemonic.set(key, agg) }
    agg.count++
    agg.total += dur[actionEvents[a]]
    for (let p = 0; p < NP; p++) agg.phases[p] += row[p]
  }
  for (let l = 1; l <= laneKeys.length; l++) if (laneOffsets[l] === 0) laneOffsets[l] = laneOffsets[l - 1]

  const critCat = catIdx.has("critical path component") ? catIdx.get("critical path component") : -1
  return {
    threads, ts, dur, lane, name, cat, arg, mnemonic, target, depth, parent, phase, actionOf,
    names, cats, args, mnemonics, targets, laneOffsets, laneMaxDur, laneDepth,
    actionEvent: Int32Array.from(actionEvents), actionPhases, phaseTotals,
    byMnemonic: [...byMnemonic.values()].sort((a, b) => b.total - a.total),
    phases: PHASES, phaseColors: PHASE_COLORS, actionCat,
    counters: [...counters.values()], markers, minTs, maxTs, critCat, eventCount: n,
  }
}
