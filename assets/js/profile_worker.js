// Web Worker: fetches a Bazel JSON profile (served with Content-Encoding: gzip, so the
// browser inflates it), parses the trace events and hands the main thread compact typed
// arrays: one lane per thread, events sorted by lane then start time, interned strings.
self.onmessage = async ({data}) => {
  try {
    const res = await fetch(data.url, {credentials: "same-origin"})
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = JSON.parse(await res.text())
    const built = build(json.traceEvents || [])
    const transfer = [built.ts.buffer, built.dur.buffer, built.lane.buffer, built.name.buffer, built.cat.buffer, built.arg.buffer, built.laneOffsets.buffer, built.laneMaxDur.buffer]
    self.postMessage({ok: true, ...built, otherData: json.otherData || {}}, transfer)
  } catch (e) {
    self.postMessage({ok: false, error: String(e && e.message ? e.message : e)})
  }
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
      let a = -1
      if (e.args) {
        const parts = []
        for (const k of ["target", "mnemonic", "out", "name"]) if (e.args[k] != null) parts.push(`${k}=${e.args[k]}`)
        if (parts.length) a = intern(args, argIdx, parts.join("  "))
      }
      xs.push({key, ts, dur, n: intern(names, nameIdx, e.name || ""), c: intern(cats, catIdx, e.cat || ""), a})
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

  xs.sort((a, b) => (laneOf.get(a.key) - laneOf.get(b.key)) || (a.ts - b.ts))
  const n = xs.length
  const ts = new Float64Array(n), dur = new Float64Array(n)
  const lane = new Int32Array(n), name = new Int32Array(n), cat = new Int32Array(n), arg = new Int32Array(n)
  const laneOffsets = new Int32Array(laneKeys.length + 1)
  const laneMaxDur = new Float64Array(laneKeys.length)
  for (let i = 0; i < n; i++) {
    const x = xs[i], l = laneOf.get(x.key)
    ts[i] = x.ts; dur[i] = x.dur; lane[i] = l; name[i] = x.n; cat[i] = x.c; arg[i] = x.a
    laneOffsets[l + 1] = i + 1
    if (x.dur > laneMaxDur[l]) laneMaxDur[l] = x.dur
  }
  for (let l = 1; l <= laneKeys.length; l++) if (laneOffsets[l] === 0) laneOffsets[l] = laneOffsets[l - 1]

  const critCat = catIdx.has("critical path component") ? catIdx.get("critical path component") : -1
  return {
    threads, ts, dur, lane, name, cat, arg, names, cats, args, laneOffsets, laneMaxDur,
    counters: [...counters.values()], markers, minTs, maxTs, critCat, eventCount: n,
  }
}
