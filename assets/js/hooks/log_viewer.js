// Terminal-style build log viewer. The log itself lives in a Web Worker (see
// ../log_core.mjs): the worker streams it from the download endpoint, applies terminal
// emulation and holds the bytes; this hook only asks for the lines that are on screen,
// renders them into a virtualized list, and forwards live appends from the LiveView socket.
import {createLogEngine} from "../log_core.mjs"

const LINE_HEIGHT = 18
const OVERSCAN = 20
const CACHE_LIMIT = 20000
const CSI_RE = /\x1b\[([0-9;?]*)([A-Za-z])/g

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Convert one line (SGR sequences only) to HTML spans.
export function ansiToHtml(line) {
  let out = ""
  let classes = new Set()
  let open = false
  const flushOpen = () => {
    if (open) { out += "</span>"; open = false }
    if (classes.size > 0) { out += `<span class="${[...classes].join(" ")}">`; open = true }
  }
  let last = 0
  CSI_RE.lastIndex = 0
  let m
  while ((m = CSI_RE.exec(line))) {
    out += escapeHtml(line.slice(last, m.index))
    last = m.index + m[0].length
    if (m[2] !== "m") continue
    const params = m[1] === "" ? ["0"] : m[1].split(";")
    for (let i = 0; i < params.length; i++) {
      const p = parseInt(params[i], 10)
      if (p === 0) classes.clear()
      else if (p === 1) classes.add("ansi-bold")
      else if (p === 2) classes.add("ansi-dim")
      else if (p === 3) classes.add("ansi-italic")
      else if (p === 4) classes.add("ansi-underline")
      else if (p === 22) { classes.delete("ansi-bold"); classes.delete("ansi-dim") }
      else if (p === 39) [...classes].filter(c => c.startsWith("ansi-fg-")).forEach(c => classes.delete(c))
      else if (p === 49) [...classes].filter(c => c.startsWith("ansi-bg-")).forEach(c => classes.delete(c))
      else if (p >= 30 && p <= 37) { [...classes].filter(c => c.startsWith("ansi-fg-")).forEach(c => classes.delete(c)); classes.add(`ansi-fg-${p - 30}`) }
      else if (p >= 90 && p <= 97) { [...classes].filter(c => c.startsWith("ansi-fg-")).forEach(c => classes.delete(c)); classes.add(`ansi-fg-${p - 90 + 8}`) }
      else if (p >= 40 && p <= 47) { [...classes].filter(c => c.startsWith("ansi-bg-")).forEach(c => classes.delete(c)); classes.add(`ansi-bg-${p - 40}`) }
      else if (p === 38 || p === 48) { if (params[i + 1] === "5") i += 2; else if (params[i + 1] === "2") i += 4 }
    }
    flushOpen()
  }
  out += escapeHtml(line.slice(last))
  if (open) out += "</span>"
  return out
}

const formatCount = (n) => n.toLocaleString()

export const LogViewer = {
  mounted() {
    this.total = 0
    this.loading = false
    this.bytes = 0
    this.matches = null
    this.filter = ""
    this.follow = true
    this.cache = new Map()
    this.pendingLines = new Set()
    this.req = 0
    this.viewport = this.el.querySelector("[data-log-viewport]")
    this.spacer = this.el.querySelector("[data-log-spacer]")
    this.content = this.el.querySelector("[data-log-content]")
    this.status = this.el.querySelector("[data-log-status]")
    this.startEngine()
    const search = this.el.querySelector("[data-log-search]")
    const followBtn = this.el.querySelector("[data-log-follow]")
    if (search) search.addEventListener("input", e => {
      clearTimeout(this.filterTimer)
      this.filterTimer = setTimeout(() => { this.filter = e.target.value; this.send({type: "filter", query: this.filter}) }, 150)
    })
    if (followBtn) followBtn.addEventListener("click", () => { this.follow = !this.follow; this.syncFollow(); if (this.follow) this.scrollToEnd() })
    this.viewport.addEventListener("scroll", () => {
      const atEnd = this.viewport.scrollTop + this.viewport.clientHeight >= this.viewport.scrollHeight - LINE_HEIGHT
      if (!atEnd && this.follow) { this.follow = false; this.syncFollow() }
      this.scheduleRender()
    })
    this.content.addEventListener("click", e => {
      const ln = e.target.closest("[data-line]")
      if (ln) { history.replaceState(null, "", `#L${ln.dataset.line}`); this.highlight = parseInt(ln.dataset.line, 10); this.render() }
    })
    this.handleEvent("log:append", ({text, offset}) => this.send({type: "append", text, offset}))
    this.handleEvent("log:reset", ({url, live}) => {
      this.follow = !!live
      this.syncFollow()
      this.cache.clear()
      this.matches = null
      const hash = window.location.hash.match(/^#L(\d+)$/)
      this.pendingScroll = hash ? {line: parseInt(hash[1], 10)} : (live ? {end: true} : null)
      if (hash) this.highlight = this.pendingScroll.line
      this.send({type: "load", url})
      if (this.filter) this.send({type: "filter", query: this.filter})
    })
    this.pushEvent("log:load", {})
  },
  destroyed() {
    cancelAnimationFrame(this.raf)
    clearTimeout(this.reloadTimer)
    clearTimeout(this.filterTimer)
    if (this.worker) this.worker.terminate()
  },
  // The engine runs in a Web Worker; without workers (or with data-inline) it runs in-page
  // on the same message protocol.
  startEngine() {
    const receive = (message) => this.receive(message)
    if (typeof Worker !== "undefined" && this.viewport.dataset.worker && !this.viewport.dataset.inline) {
      this.worker = new Worker(this.viewport.dataset.worker)
      this.worker.onmessage = ({data}) => receive(data)
      this.send = (message) => this.worker.postMessage(message)
    } else {
      const engine = createLogEngine(receive)
      this.send = (message) => engine(message)
    }
  },
  receive(message) {
    switch (message.type) {
      case "count": {
        const previous = this.total
        this.total = message.lines
        this.loading = message.loading
        this.bytes = message.bytes
        // The old last line and anything at or beyond the new end may have changed.
        const from = Math.min(previous, this.total)
        if (from > 0 || previous !== this.total) for (const n of this.cache.keys()) if (n >= from) this.cache.delete(n)
        if (this.matches === null) this.render()
        if (!this.loading && this.pendingScroll) {
          const target = this.pendingScroll
          this.pendingScroll = null
          if (target.line) this.scrollToLine(target.line); else if (target.end) this.scrollToEnd()
        } else if (this.follow && !this.loading) this.scrollToEnd()
        break
      }
      case "filter":
        this.matches = message.query ? message.matches : null
        this.render()
        break
      case "lines":
        for (let i = 0; i < message.numbers.length; i++) { this.cache.set(message.numbers[i], message.texts[i]); this.pendingLines.delete(message.numbers[i]) }
        if (this.cache.size > CACHE_LIMIT) { const keep = new Set(message.numbers); for (const n of this.cache.keys()) if (!keep.has(n)) this.cache.delete(n) }
        this.render()
        break
      case "gap":
        // An append is ahead of what we have (not committed yet when we loaded, or lost on
        // a socket reconnect): reload shortly; the queued appends splice in afterwards.
        if (!this.reloadTimer) this.reloadTimer = setTimeout(() => { this.reloadTimer = null; this.pushEvent("log:load", {}) }, 1000)
        break
      case "error":
        if (this.status) this.status.textContent = message.message
        break
    }
  },
  rowCount() { return this.matches ? this.matches.length : this.total },
  lineNumber(row) { return this.matches ? this.matches[row] + 1 : row + 1 },
  scheduleRender() { if (!this.raf) this.raf = requestAnimationFrame(() => { this.raf = null; this.render() }) },
  render() {
    const rows = this.rowCount()
    this.spacer.style.height = `${rows * LINE_HEIGHT}px`
    const first = Math.max(0, Math.floor(this.viewport.scrollTop / LINE_HEIGHT) - OVERSCAN)
    const last = Math.min(rows, Math.ceil((this.viewport.scrollTop + this.viewport.clientHeight) / LINE_HEIGHT) + OVERSCAN)
    const missing = []
    let html = ""
    for (let i = first; i < last; i++) {
      const n = this.lineNumber(i)
      const text = this.cache.get(n)
      if (text === undefined && !this.pendingLines.has(n)) { missing.push(n); this.pendingLines.add(n) }
      const hl = n === this.highlight ? " bg-amber-500/20" : ""
      html += `<div class="flex whitespace-pre${hl}" style="height:${LINE_HEIGHT}px" data-line="${n}"><span class="ln w-12 shrink-0 select-none pr-3 text-right">${n}</span><span>${text === undefined ? "" : ansiToHtml(text)}</span></div>`
    }
    this.content.style.transform = `translateY(${first * LINE_HEIGHT}px)`
    this.content.innerHTML = html
    if (missing.length > 0) this.send({type: "lines", req: ++this.req, numbers: missing})
    if (this.status) {
      const parts = [this.matches ? `${formatCount(rows)} of ${formatCount(this.total)} lines match` : `${formatCount(this.total)} lines`]
      if (this.loading) parts.push(`loading… ${(this.bytes / (1024 * 1024)).toFixed(1)} MB`)
      this.status.textContent = parts.join(" · ")
    }
  },
  scrollToEnd() { this.viewport.scrollTop = this.viewport.scrollHeight; this.render() },
  scrollToLine(n) { this.viewport.scrollTop = Math.max(0, (n - 5) * LINE_HEIGHT); this.render() },
  syncFollow() {
    const btn = this.el.querySelector("[data-log-follow]")
    if (btn) { btn.setAttribute("aria-pressed", String(this.follow)); btn.classList.toggle("bg-base-content", this.follow); btn.classList.toggle("text-base-100", this.follow) }
  },
}
