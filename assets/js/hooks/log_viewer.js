// Terminal-style build log viewer. The server sends the full log once (reply to "log:load")
// and then appends chunks ("log:append"). Lines are kept in memory, ANSI SGR codes become
// CSS classes, cursor-movement sequences are emulated so progress lines are overwritten the
// way a terminal shows them, and only the visible window of lines is in the DOM.
const LINE_HEIGHT = 18
const OVERSCAN = 20

const ESC = "\x1b"
const CSI_RE = /\x1b\[([0-9;?]*)([A-Za-z])/g

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Convert one line (already free of cursor codes except SGR) to HTML spans.
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

// Feed raw text into a line buffer, emulating \r overwrites and cursor-up/clear sequences.
export function feed(state, text) {
  let lines = state.lines
  let partial = state.partial
  let i = 0
  while (i < text.length) {
    const ch = text[i]
    if (ch === "\n") {
      lines.push(partial); partial = ""; i++
    } else if (ch === "\r") {
      if (text[i + 1] === "\n") { i++; continue }
      partial = ""; i++
    } else if (ch === ESC && text[i + 1] === "[") {
      CSI_RE.lastIndex = i
      const m = CSI_RE.exec(text)
      if (!m || m.index !== i) { partial += ch; i++; continue }
      const cmd = m[2]
      const n = parseInt(m[1] || "1", 10) || 1
      if (cmd === "A") { for (let k = 0; k < n && lines.length > 0; k++) lines.pop(); partial = "" }
      else if (cmd === "K" || cmd === "J") { /* clear to end: nothing to keep after this point */ }
      else if (cmd === "m") { partial += m[0] }
      i += m[0].length
    } else {
      partial += ch; i++
    }
  }
  state.partial = partial
  return state
}

export const LogViewer = {
  mounted() {
    this.state = {lines: [], partial: ""}
    this.filter = ""
    this.follow = true
    this.viewport = this.el.querySelector("[data-log-viewport]")
    this.spacer = this.el.querySelector("[data-log-spacer]")
    this.content = this.el.querySelector("[data-log-content]")
    this.status = this.el.querySelector("[data-log-status]")
    const search = this.el.querySelector("[data-log-search]")
    const followBtn = this.el.querySelector("[data-log-follow]")
    if (search) search.addEventListener("input", e => { this.filter = e.target.value.toLowerCase(); this.render(true) })
    if (followBtn) followBtn.addEventListener("click", () => { this.follow = !this.follow; this.syncFollow(); if (this.follow) this.scrollToEnd() })
    this.viewport.addEventListener("scroll", () => {
      const atEnd = this.viewport.scrollTop + this.viewport.clientHeight >= this.viewport.scrollHeight - LINE_HEIGHT
      if (!atEnd && this.follow) { this.follow = false; this.syncFollow() }
      this.scheduleRender()
    })
    this.content.addEventListener("click", e => {
      const ln = e.target.closest("[data-line]")
      if (ln) { history.replaceState(null, "", `#L${ln.dataset.line}`); this.highlight = parseInt(ln.dataset.line, 10); this.render(true) }
    })
    this.handleEvent("log:append", ({text}) => { feed(this.state, text); this.render(true); if (this.follow) this.scrollToEnd() })
    this.handleEvent("log:reset", ({text, live, truncated}) => {
      this.state = feed({lines: [], partial: ""}, (truncated ? "… (log truncated, download for the full output)\n" : "") + (text || ""))
      this.follow = !!live
      this.syncFollow()
      this.render(true)
      const hash = window.location.hash.match(/^#L(\d+)$/)
      if (hash) { this.highlight = parseInt(hash[1], 10); this.scrollToLine(this.highlight) } else if (live) this.scrollToEnd()
    })
    this.pushEvent("log:load", {})
  },
  destroyed() { cancelAnimationFrame(this.raf) },
  visibleLines() {
    const all = this.state.partial ? [...this.state.lines, this.state.partial] : this.state.lines
    if (!this.filter) return all.map((text, i) => [i + 1, text])
    const f = this.filter
    const out = []
    for (let i = 0; i < all.length; i++) if (all[i].toLowerCase().includes(f)) out.push([i + 1, all[i]])
    return out
  },
  scheduleRender() { if (!this.raf) this.raf = requestAnimationFrame(() => { this.raf = null; this.render(false) }) },
  render(recount) {
    if (recount || !this.rows) this.rows = this.visibleLines()
    const rows = this.rows
    this.spacer.style.height = `${rows.length * LINE_HEIGHT}px`
    const first = Math.max(0, Math.floor(this.viewport.scrollTop / LINE_HEIGHT) - OVERSCAN)
    const last = Math.min(rows.length, Math.ceil((this.viewport.scrollTop + this.viewport.clientHeight) / LINE_HEIGHT) + OVERSCAN)
    let html = ""
    for (let i = first; i < last; i++) {
      const [n, text] = rows[i]
      const hl = n === this.highlight ? " bg-amber-500/20" : ""
      html += `<div class="flex whitespace-pre${hl}" style="height:${LINE_HEIGHT}px" data-line="${n}"><span class="ln w-12 shrink-0 select-none pr-3 text-right">${n}</span><span>${ansiToHtml(text)}</span></div>`
    }
    this.content.style.transform = `translateY(${first * LINE_HEIGHT}px)`
    this.content.innerHTML = html
    if (this.status) this.status.textContent = this.filter ? `${rows.length} matching lines` : `${rows.length} lines`
  },
  scrollToEnd() { this.viewport.scrollTop = this.viewport.scrollHeight },
  scrollToLine(n) { this.viewport.scrollTop = Math.max(0, (n - 5) * LINE_HEIGHT); this.render(false) },
  syncFollow() {
    const btn = this.el.querySelector("[data-log-follow]")
    if (btn) { btn.setAttribute("aria-pressed", String(this.follow)); btn.classList.toggle("bg-base-content", this.follow); btn.classList.toggle("text-base-100", this.follow) }
  },
}
