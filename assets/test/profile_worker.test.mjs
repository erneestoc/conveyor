import {test} from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import zlib from "node:zlib"
import {build, classify, PHASES} from "../js/profile_worker.js"

const X = (tid, cat, name, ts, dur, args) => ({ph: "X", pid: 1, tid, cat, name, ts, dur, args})
const P = (p) => PHASES.indexOf(p)

test("nesting, parents and per-action phase attribution", () => {
  const events = [
    {ph: "M", pid: 1, tid: 7, name: "thread_name", args: {name: "skyframe-evaluator 7"}},
    {ph: "M", pid: 1, tid: 7, name: "thread_sort_index", args: {sort_index: 1}},
    {ph: "M", pid: 1, tid: 8, name: "thread_sort_index", args: {sort_index: 2}},
    X(7, "action processing", "Compiling foo.cc", 0, 1000, {target: "//a:foo", mnemonic: "CppCompile"}),
    X(7, "remote action cache check", "check cache hit", 0, 100),
    X(7, "Remote execution upload time", "upload missing inputs", 100, 200),
    X(7, "remote action execution", "execute remotely", 300, 500),
    X(7, "remote network", "remote network", 400, 100), // nested inside execution: not double counted
    X(7, "remote output download", "download outputs", 800, 100),
    X(7, "action processing", "Linking bar", 2000, 300, {target: "//a:bar", mnemonic: "CppLink"}),
    X(7, "local action execution", "subprocess.run", 2050, 200),
    X(7, "complete action execution", "actuallyCompleteAction", 2260, 40),
    X(8, "general information", "unrelated", 0, 50),
  ]
  const b = build(events)
  assert.equal(b.eventCount, 10)
  assert.equal(b.threads[0].name, "skyframe-evaluator 7")
  assert.deepEqual(Array.from(b.depth.slice(0, 7)), [0, 1, 1, 1, 2, 1, 0])
  assert.equal(b.parent[4], 3) // remote network inside execute remotely
  assert.equal(b.parent[0], -1)
  assert.equal(b.laneDepth[0], 3)
  assert.equal(b.actionEvent.length, 2)
  const row = (a) => Array.from(b.actionPhases.slice(a * PHASES.length, (a + 1) * PHASES.length))
  const r0 = row(0)
  assert.equal(r0[P("cache check")], 100)
  assert.equal(r0[P("upload inputs")], 200)
  assert.equal(r0[P("remote execution")], 500)
  assert.equal(r0[P("download outputs")], 100)
  assert.equal(r0[P("other")], 100)
  const r1 = row(1)
  assert.equal(r1[P("local execution")], 200)
  assert.equal(r1[P("outputs")], 40)
  assert.equal(r1[P("other")], 60)
  assert.equal(b.phaseTotals[P("remote execution")], 500)
  assert.deepEqual(b.byMnemonic.map(m => [m.name, m.count, m.total]), [["CppCompile", 1, 1000], ["CppLink", 1, 300]])
  assert.equal(b.mnemonics[b.mnemonic[0]], "CppCompile")
  assert.equal(b.targets[b.target[6]], "//a:bar")
  assert.equal(b.actionOf[4], 0)
  assert.equal(b.actionOf[9], -1)
})

test("classify covers the spawn runner vocabulary", () => {
  assert.equal(PHASES[classify("remote action cache check", "check cache hit")], "cache check")
  assert.equal(PHASES[classify("Remote execution upload time", "upload missing inputs")], "upload inputs")
  assert.equal(PHASES[classify("Remote execution queuing time", "queued")], "queued")
  assert.equal(PHASES[classify("remote output download", "download outputs")], "download outputs")
  assert.equal(PHASES[classify("local execution in worker", "worker")], "local execution")
  assert.equal(PHASES[classify("Staging local action file system", "x")], "setup")
  assert.equal(PHASES[classify("general information", "misc")], "other")
})

test("the recorded fixture profile builds", () => {
  const gz = fs.readFileSync("test/fixtures/blobs/c9fb9e145e0fbb8955f0a0f93e7cfa750e3ab9e6e15387e5caacf811cfa7ec86")
  const json = JSON.parse(zlib.gunzipSync(gz).toString())
  const b = build(json.traceEvents)
  assert.equal(b.eventCount, 1297)
  assert.ok(b.threads.length >= 50)
  assert.equal(b.actionEvent.length, 8)
  assert.ok(b.markers.length > 0 && b.counters.length > 0)
})
