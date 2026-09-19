import {test} from "node:test"
import assert from "node:assert/strict"
import {LogBuffer, createLogEngine, scan} from "../js/log_core.mjs"

const enc = new TextEncoder()
const feed = (buf, text) => buf.feed(enc.encode(text))
const all = (buf) => Array.from({length: buf.lines()}, (_, i) => buf.line(i))

test("lines, partial line and \\r overwrite", () => {
  const buf = new LogBuffer()
  feed(buf, "one\ntwo\npartial")
  assert.deepEqual(all(buf), ["one", "two", "partial"])
  feed(buf, "\rreplaced\r\nthree\n")
  assert.deepEqual(all(buf), ["one", "two", "replaced", "three"])
  assert.equal(buf.lines(), 4)
})

test("cursor up discards previous lines; SGR is kept; other CSI dropped", () => {
  const buf = new LogBuffer()
  feed(buf, "a\n[1 / 2] compiling\n[2 / 2] linking\n\x1b[2A\x1b[K\x1b[32mINFO:\x1b[0m done\n")
  assert.deepEqual(all(buf), ["a", "\x1b[32mINFO:\x1b[0m done"])
})

test("escape sequences and \\r split across chunks", () => {
  const buf = new LogBuffer()
  feed(buf, "x\ny\n\x1b[")
  feed(buf, "1A")
  feed(buf, "z\r")
  feed(buf, "\nw")
  assert.deepEqual(all(buf), ["x", "z", "w"])
})

test("multi-byte text and page boundaries survive", () => {
  const buf = new LogBuffer()
  const line = "héllo wörld ✓ ".repeat(50)
  const lines = 400_000 // ~ 280 MB / 4 MiB pages: crosses many pages
  const chunk = enc.encode((line + "\n").repeat(1000))
  for (let i = 0; i < lines / 1000; i++) buf.feed(chunk)
  assert.equal(buf.lines(), lines)
  assert.equal(buf.line(0), line)
  assert.equal(buf.line(lines - 1), line)
  assert.equal(buf.line(123_456), line)
})

test("scan is case-insensitive", () => {
  const buf = new LogBuffer()
  feed(buf, "Error: a\nfine\nERROR: b\n")
  assert.deepEqual(scan(buf, "error", 0, buf.lines(), []), [0, 2])
})

test("engine loads over fetch, splices appends by offset and filters incrementally", async () => {
  const messages = []
  const body = "first\nsecond\nthird"
  const fetchImpl = async () => new Response(enc.encode(body), {status: 200})
  const engine = createLogEngine((m) => messages.push(m), fetchImpl)
  engine({type: "append", text: " (early)\n", offset: body.length}) // before the load: queued
  engine({type: "load", url: "/log"})
  await new Promise(r => setTimeout(r, 20))
  const last = () => messages.filter(m => m.type === "count").pop()
  assert.equal(last().lines, 3)
  assert.equal(last().loading, false)
  assert.ok(!messages.some(m => m.type === "gap"))
  engine({type: "append", text: "third (dup)\n", offset: 7}) // overlaps loaded bytes: ignored
  engine({type: "lines", req: 1, numbers: [1, 3]})
  assert.deepEqual(messages.find(m => m.type === "lines").texts, ["first", "third (early)"])
  engine({type: "filter", query: "IR"})
  let f = messages.filter(m => m.type === "filter").pop()
  assert.deepEqual(Array.from(f.matches), [0, 2])
  const loaded = body.length + " (early)\n".length
  engine({type: "append", text: "fourth\n", offset: loaded + 8}) // ahead of us: gap, stays queued
  assert.ok(messages.some(m => m.type === "gap"))
  assert.equal(last().lines, 3)
  engine({type: "append", text: "\nthirty\n", offset: loaded}) // fills the gap; both apply
  assert.equal(last().lines, 6)
  engine({type: "lines", req: 2, numbers: [4, 5, 6]})
  assert.deepEqual(messages.filter(m => m.type === "lines").pop().texts, ["", "thirty", "fourth"])
  f = messages.filter(m => m.type === "filter").pop()
  assert.deepEqual(Array.from(f.matches), [0, 2, 4])
  engine({type: "filter", query: ""})
  assert.equal(messages.filter(m => m.type === "filter").pop().matches.length, 0)
})
