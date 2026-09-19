// Canvas flame-style timeline for Bazel JSON profiles. A Web Worker fetches and parses the
// profile (see ../profile_worker.js); this hook draws one lane per thread with nested
// events as flame rows, a minimap with a draggable viewport, wheel zoom, drag pan,
// shift-drag range selection, keyboard navigation, hover tooltips with a time cursor,
// click details with the per-action phase breakdown, search, category and critical-path
// filters, lane collapsing, and a "where the time went" panel by phase and mnemonic.
// Only the visible time range is drawn and sub-pixel events are coalesced.
import {build, PHASE_COLORS} from "../profile_worker"

const ROW_H = 18
const GUTTER = 220
const AXIS_H = 22
const COUNTER_H = 48
const MAX_DEPTH = 6
const MINIMAP_H = 44
const PALETTE = ["#3b82f6", "#10b981", "#f59e0b", "#8b5cf6", "#ec4899", "#14b8a6", "#f97316", "#6366f1", "#84cc16", "#06b6d4", "#a855f7", "#ef4444"]

export function fmtUs(us) {
  const ms = us / 1000
  if (Math.abs(ms) < 1) return `${us.toFixed(0)} µs`
  if (Math.abs(ms) < 1000) return `${ms.toFixed(ms < 10 ? 2 : 1)} ms`
  const s = ms / 1000
  if (s < 60) return `${s.toFixed(s < 10 ? 2 : 1)} s`
  return `${Math.floor(s / 60)}m ${(s % 60).toFixed(1)}s`
}

function niceStep(rangeUs, px) {
  const target = rangeUs / Math.max(px / 110, 1)
  const pow = Math.pow(10, Math.floor(Math.log10(target)))
  for (const m of [1, 2, 5, 10]) if (m * pow >= target) return m * pow
  return 10 * pow
}

function lowerBound(arr, from, to, value) {
  let lo = from, hi = to
  while (lo < hi) { const mid = (lo + hi) >> 1; if (arr[mid] < value) lo = mid + 1; else hi = mid }
  return lo
}

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
const pct = (part, whole) => whole > 0 ? `${(100 * part / whole).toFixed(part / whole < 0.1 ? 1 : 0)}%` : "0%"

// Stacked bar + legend for a phase row (Float64Array or array of NP durations).
export function phaseBarHtml(row, phases, colors, total) {
  const sum = row.reduce((a, b) => a + b, 0) || 1
  const segs = [], legend = []
  for (let p = 0; p < row.length; p++) {
    if (row[p] <= 0) continue
    segs.push(`<div style="width:${(100 * row[p] / sum).toFixed(2)}%;background:${colors[p]}" title="${esc(phases[p])}: ${fmtUs(row[p])}"></div>`)
    legend.push(`<span class="inline-flex items-center gap-1"><i class="inline-block h-2 w-2 rounded-sm" style="background:${colors[p]}"></i>${esc(phases[p])} ${fmtUs(row[p])} <span class="text-base-content/50">${pct(row[p], total ?? sum)}</span></span>`)
  }
  return `<div class="flex h-2.5 w-full overflow-hidden rounded bg-base-200">${segs.join("")}</div><div class="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px]">${legend.join("")}</div>`
}

export const ProfileTimeline = {
  mounted() {
    this.canvas = this.el.querySelector("canvas[data-role=plot]")
    this.minimap = this.el.querySelector("canvas[data-role=minimap]")
    this.scroller = this.el.querySelector("[data-role=scroller]")
    this.status = this.el.querySelector("[data-role=status]")
    this.tooltip = this.el.querySelector("[data-role=tooltip]")
    this.details = this.el.querySelector("[data-role=details]")
    this.breakdown = this.el.querySelector("[data-role=breakdown]")
    this.search = this.el.querySelector("[data-role=search]")
    this.category = this.el.querySelector("[data-role=category]")
    this.critical = this.el.querySelector("[data-role=critical]")
    this.reset = this.el.querySelector("[data-role=reset]")
    this.ctx = this.canvas.getContext("2d")
    this.mctx = this.minimap ? this.minimap.getContext("2d") : null
    this.filter = ""
    this.catFilter = -1
    this.critOnly = false
    this.collapsed = new Set()
    this.selected = -1
    this.selection = null
    this.cursorT = null
    this.raf = null

    this.setStatus("Loading profile…")
    this.load()

    this.onWheel = e => this.wheel(e)
    this.onDown = e => this.pointerDown(e)
    this.onMove = e => this.mouseMove(e)
    this.onUp = e => this.pointerUp(e)
    this.onLeave = () => { this.tooltip.hidden = true; this.cursorT = null; this.schedule() }
    this.onClick = e => this.click(e)
    this.onDbl = e => this.doubleClick(e)
    this.onKey = e => this.key(e)
    this.onResize = () => this.schedule()
    this.canvas.addEventListener("wheel", this.onWheel, {passive: false})
    this.canvas.addEventListener("mousedown", this.onDown)
    window.addEventListener("mousemove", this.onMove)
    window.addEventListener("mouseup", this.onUp)
    this.canvas.addEventListener("mouseleave", this.onLeave)
    this.canvas.addEventListener("click", this.onClick)
    this.canvas.addEventListener("dblclick", this.onDbl)
    this.canvas.addEventListener("keydown", this.onKey)
    window.addEventListener("resize", this.onResize)
    if (this.minimap) {
      this.onMiniDown = e => this.minimapDown(e)
      this.minimap.addEventListener("mousedown", this.onMiniDown)
    }
    if (this.search) this.search.addEventListener("input", () => { this.filter = this.search.value.trim().toLowerCase(); this.schedule() })
    if (this.category) this.category.addEventListener("change", () => { this.catFilter = parseInt(this.category.value, 10); this.schedule() })
    if (this.critical) this.critical.addEventListener("change", () => { this.critOnly = this.critical.checked; this.schedule() })
    if (this.reset) this.reset.addEventListener("click", () => this.resetView())
    this.el.addEventListener("click", e => {
      const btn = e.target.closest("[data-action]")
      if (!btn) return
      const i = parseInt(btn.dataset.event, 10)
      if (btn.dataset.action === "zoom" && !isNaN(i)) this.zoomTo(i)
      if (btn.dataset.action === "select" && !isNaN(i)) { this.select(i); this.zoomTo(i) }
      if (btn.dataset.action === "search") { this.search.value = btn.dataset.query || ""; this.search.dispatchEvent(new Event("input")) }
    })
  },

  destroyed() {
    if (this.worker) this.worker.terminate()
    if (this.raf) cancelAnimationFrame(this.raf)
    window.removeEventListener("mousemove", this.onMove)
    window.removeEventListener("mouseup", this.onUp)
    window.removeEventListener("resize", this.onResize)
  },

  setStatus(text) { if (this.status) this.status.textContent = text },

  // Parse in a Web Worker so a 100 MB profile never blocks the page; fall back to the main
  // thread when workers are unavailable (or data-inline is set).
  load() {
    const url = this.el.dataset.url
    if (this.el.dataset.inline === "true" || typeof Worker === "undefined") return this.loadInline(url)
    try {
      this.worker = new Worker(this.el.dataset.worker)
    } catch (_e) {
      return this.loadInline(url)
    }
    this.worker.onmessage = ({data}) => {
      if (!data.ok) { this.setStatus(`Could not load the profile: ${data.error}`); return }
      this.loaded(data)
    }
    this.worker.onerror = () => { this.worker.terminate(); this.worker = null; this.loadInline(url) }
    this.worker.postMessage({url})
  },

  async loadInline(url) {
    try {
      const res = await fetch(url, {credentials: "same-origin"})
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = JSON.parse(await res.text())
      this.loaded({...build(json.traceEvents || []), otherData: json.otherData || {}})
    } catch (e) {
      this.setStatus(`Could not load the profile: ${e.message || e}`)
    }
  },

  loaded(data) {
    this.data = data
    this.view = [data.minTs, Math.max(data.maxTs, data.minTs + 1)]
    this.fillCategories()
    this.setStatus(`${data.eventCount.toLocaleString()} events · ${data.threads.length} threads · ${fmtUs(data.maxTs - data.minTs)}`)
    this.renderBreakdown()
    this.el.dataset.loaded = "true"
    this.schedule()
  },

  fillCategories() {
    if (!this.category) return
    const cats = this.data.cats.map((c, i) => [c, i]).sort((a, b) => a[0].localeCompare(b[0]))
    this.category.innerHTML = `<option value="-1">All categories</option>` +
      cats.map(([c, i]) => `<option value="${i}">${esc(c)}</option>`).join("")
  },

  resetView() { if (this.data) { this.view = [this.data.minTs, Math.max(this.data.maxTs, this.data.minTs + 1)]; this.selection = null; this.schedule() } },
  setView(v0, v1) {
    const d = this.data
    const span = Math.max(d.maxTs - d.minTs, 1)
    let range = Math.min(Math.max(v1 - v0, 20), span * 2)
    let start = Math.min(Math.max(v0, d.minTs - span), d.maxTs)
    this.view = [start, start + range]
    this.schedule()
  },
  zoomTo(i) {
    const d = this.data
    const pad = Math.max(d.dur[i] * 0.1, 50)
    this.setView(d.ts[i] - pad, d.ts[i] + d.dur[i] + pad)
    const laneTop = this.laneTops()[d.lane[i]]
    if (this.scroller) this.scroller.scrollTop = Math.max(laneTop - 60, 0)
  },

  schedule() { if (!this.raf) this.raf = requestAnimationFrame(() => { this.raf = null; this.render() }) },

  // --- geometry ---------------------------------------------------------------------------
  plotWidth() { return Math.max(this.canvas.clientWidth - GUTTER, 50) },
  counterHeight() { return this.data && this.data.counters.length ? COUNTER_H : 0 },
  topOffset() { return AXIS_H + this.counterHeight() },
  xOf(t) { return GUTTER + (t - this.view[0]) / (this.view[1] - this.view[0]) * this.plotWidth() },
  tOf(x) { return this.view[0] + (x - GUTTER) / this.plotWidth() * (this.view[1] - this.view[0]) },
  laneRows(l) { return this.collapsed.has(l) ? 1 : Math.min(Math.max(this.data.laneDepth[l], 1), MAX_DEPTH) },
  // Cumulative y offsets per lane (cached per render).
  laneTops() {
    if (this._laneTops && this._laneTopsKey === this.collapsed.size) return this._laneTops
    const d = this.data
    const tops = new Float64Array(d.threads.length + 1)
    let y = this.topOffset()
    for (let l = 0; l < d.threads.length; l++) { tops[l] = y; y += this.laneRows(l) * ROW_H }
    tops[d.threads.length] = y
    this._laneTops = tops
    this._laneTopsKey = this.collapsed.size
    return tops
  },
  laneAt(y) {
    const tops = this.laneTops()
    let lo = 0, hi = this.data.threads.length
    while (lo < hi) { const mid = (lo + hi) >> 1; if (tops[mid + 1] <= y) lo = mid + 1; else hi = mid }
    return lo < this.data.threads.length ? lo : -1
  },

  visible(i) {
    const d = this.data
    if (this.critOnly && d.cat[i] !== d.critCat) return false
    if (this.catFilter >= 0 && d.cat[i] !== this.catFilter) return false
    if (this.filter) {
      if (d.names[d.name[i]].toLowerCase().includes(this.filter)) return true
      const a = d.arg[i] >= 0 ? d.args[d.arg[i]].toLowerCase() : ""
      return a.includes(this.filter)
    }
    return true
  },

  colorOf(i) {
    const d = this.data
    if (d.cat[i] === d.critCat) return "#ef4444"
    if (d.phase[i] > 0) return PHASE_COLORS[d.phase[i]]
    return PALETTE[d.cat[i] % PALETTE.length]
  },

  // --- drawing ----------------------------------------------------------------------------
  render() {
    if (!this.data) return
    const d = this.data
    const dpr = window.devicePixelRatio || 1
    const width = this.el.clientWidth
    this._laneTops = null
    const tops = this.laneTops()
    const height = tops[d.threads.length]
    this.canvas.style.width = `${width}px`
    this.canvas.style.height = `${height}px`
    this.canvas.width = Math.round(width * dpr)
    this.canvas.height = Math.round(height * dpr)
    const ctx = this.ctx
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, width, height)
    const style = getComputedStyle(this.el)
    const fg = style.color
    ctx.font = "11px ui-monospace, SFMono-Regular, Menlo, monospace"
    const plotW = this.plotWidth()
    const [v0, v1] = this.view

    // Axis
    ctx.fillStyle = fg
    ctx.globalAlpha = 0.6
    const step = niceStep(v1 - v0, plotW)
    const first = Math.ceil((v0 - d.minTs) / step) * step + d.minTs
    ctx.textAlign = "center"
    for (let t = first; t <= v1; t += step) {
      const x = this.xOf(t)
      if (x < GUTTER) continue
      ctx.fillText(fmtUs(t - d.minTs), x, 13)
      ctx.globalAlpha = 0.15
      ctx.fillRect(x, AXIS_H, 1, height - AXIS_H)
      ctx.globalAlpha = 0.6
    }
    for (const m of d.markers) {
      if (m.ts < v0 || m.ts > v1) continue
      const x = this.xOf(m.ts)
      ctx.globalAlpha = 0.5
      ctx.fillStyle = "#f59e0b"
      ctx.fillRect(x, AXIS_H - 4, 1, height)
      ctx.textAlign = "left"
      ctx.fillText(m.name, x + 3, AXIS_H - 6)
      ctx.fillStyle = fg
    }
    ctx.globalAlpha = 1

    // Counters (first numeric series of up to three counters, as small area charts)
    if (d.counters.length) {
      const chosen = d.counters.slice(0, 3)
      const h = COUNTER_H / chosen.length
      chosen.forEach((c, ci) => {
        const key = Object.keys(c.series)[0]
        if (!key) return
        const series = c.series[key]
        const max = Math.max(...series, 1)
        const y0 = AXIS_H + ci * h
        ctx.fillStyle = PALETTE[(ci + 4) % PALETTE.length]
        ctx.globalAlpha = 0.35
        ctx.beginPath()
        ctx.moveTo(GUTTER, y0 + h)
        for (let i = 0; i < c.ts.length; i++) {
          const x = Math.min(Math.max(this.xOf(c.ts[i]), GUTTER), GUTTER + plotW)
          ctx.lineTo(x, y0 + h - (series[i] / max) * (h - 4))
        }
        ctx.lineTo(GUTTER + plotW, y0 + h)
        ctx.closePath()
        ctx.fill()
        ctx.globalAlpha = 0.7
        ctx.fillStyle = fg
        ctx.textAlign = "right"
        const label = `${c.name} ≤ ${Number.isInteger(max) ? max : max.toPrecision(3)}`
        ctx.fillText(label.length > 30 ? label.slice(0, 29) + "…" : label, GUTTER - 6, y0 + h - 4)
        ctx.globalAlpha = 1
      })
    }

    // Lanes with flame rows
    const filtering = this.filter || this.catFilter >= 0 || this.critOnly
    const pxUs = (v1 - v0) / plotW
    for (let l = 0; l < d.threads.length; l++) {
      const y = tops[l], rows = this.laneRows(l), laneH = rows * ROW_H
      ctx.fillStyle = fg
      ctx.globalAlpha = l % 2 ? 0.04 : 0
      ctx.fillRect(0, y, width, laneH)
      ctx.globalAlpha = 0.75
      ctx.textAlign = "right"
      const tn = d.threads[l].name
      const mark = this.collapsed.has(l) ? "▸ " : (d.laneDepth[l] > 1 ? "▾ " : "")
      const label = mark + tn
      ctx.fillText(label.length > 30 ? label.slice(0, 29) + "…" : label, GUTTER - 6, y + 13)
      ctx.globalAlpha = 1

      const from = d.laneOffsets[l], to = d.laneOffsets[l + 1]
      if (from === to) continue
      let i = lowerBound(d.ts, from, to, v0 - d.laneMaxDur[l])
      const lastX = new Float64Array(rows).fill(-Infinity)
      for (; i < to; i++) {
        const t0 = d.ts[i]
        if (t0 > v1) break
        const t1 = t0 + d.dur[i]
        if (t1 < v0) continue
        const depth = this.collapsed.has(l) ? 0 : Math.min(d.depth[i], rows - 1)
        if (this.collapsed.has(l) && d.depth[i] > 0) continue
        const x0 = Math.max(this.xOf(t0), GUTTER)
        const x1 = Math.min(this.xOf(t1), GUTTER + plotW)
        const w = Math.max(x1 - x0, 1)
        if (x0 + w <= lastX[depth] + 0.5) continue
        lastX[depth] = x0 + w
        const vis = !filtering || this.visible(i)
        const ry = y + depth * ROW_H
        ctx.globalAlpha = vis ? (d.dur[i] < pxUs ? 0.55 : 1) : 0.12
        ctx.fillStyle = this.colorOf(i)
        ctx.fillRect(x0, ry + 3, w, ROW_H - 6)
        if (i === this.selected) {
          ctx.globalAlpha = 1
          ctx.strokeStyle = fg
          ctx.lineWidth = 2
          ctx.strokeRect(x0 - 1, ry + 2, w + 2, ROW_H - 4)
        }
        if (w > 30 && vis) {
          ctx.fillStyle = "#fff"
          ctx.textAlign = "left"
          const text = d.names[d.name[i]]
          const maxChars = Math.floor((w - 6) / 6.5)
          ctx.fillText(text.length > maxChars ? text.slice(0, Math.max(maxChars - 1, 0)) + "…" : text, x0 + 3, ry + 13)
        }
      }
      ctx.globalAlpha = 1
    }

    // Selection and time cursor
    if (this.selection) {
      const [s0, s1] = this.selection
      const x0 = Math.max(this.xOf(Math.min(s0, s1)), GUTTER), x1 = Math.min(this.xOf(Math.max(s0, s1)), GUTTER + plotW)
      ctx.fillStyle = "#3b82f6"
      ctx.globalAlpha = 0.15
      ctx.fillRect(x0, AXIS_H, x1 - x0, height - AXIS_H)
      ctx.globalAlpha = 0.9
      ctx.fillStyle = fg
      ctx.textAlign = "center"
      ctx.fillText(fmtUs(Math.abs(s1 - s0)), (x0 + x1) / 2, AXIS_H - 6)
      ctx.globalAlpha = 1
    }
    if (this.cursorT != null && !this.selection) {
      const x = this.xOf(this.cursorT)
      ctx.fillStyle = fg
      ctx.globalAlpha = 0.35
      ctx.fillRect(x, AXIS_H, 1, height - AXIS_H)
      ctx.globalAlpha = 0.9
      ctx.textAlign = "center"
      ctx.fillText(fmtUs(this.cursorT - d.minTs), x, AXIS_H - 6)
      ctx.globalAlpha = 1
    }
    this.renderMinimap(fg, dpr)
  },

  // Overview of the whole build: busy time per pixel column across all lanes, with the
  // current viewport as a draggable window.
  renderMinimap(fg, dpr) {
    if (!this.mctx) return
    const d = this.data
    const width = this.el.clientWidth
    this.minimap.style.width = `${width}px`
    this.minimap.style.height = `${MINIMAP_H}px`
    this.minimap.width = Math.round(width * dpr)
    this.minimap.height = Math.round(MINIMAP_H * dpr)
    const ctx = this.mctx
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, width, MINIMAP_H)
    const plotW = width - GUTTER
    const span = Math.max(d.maxTs - d.minTs, 1)
    if (!this._density || this._density.length !== plotW) {
      const density = new Float64Array(plotW)
      for (let i = 0; i < d.eventCount; i++) {
        if (d.depth[i] !== 0) continue
        const a = Math.floor((d.ts[i] - d.minTs) / span * plotW), b = Math.min(Math.ceil((d.ts[i] + d.dur[i] - d.minTs) / span * plotW), plotW - 1)
        for (let x = Math.max(a, 0); x <= b; x++) density[x] += 1
      }
      this._density = density
      this._densityMax = Math.max(...density, 1)
    }
    ctx.fillStyle = "#3b82f6"
    ctx.globalAlpha = 0.5
    for (let x = 0; x < plotW; x++) {
      const h = (this._density[x] / this._densityMax) * (MINIMAP_H - 6)
      if (h > 0) ctx.fillRect(GUTTER + x, MINIMAP_H - 3 - h, 1, h)
    }
    ctx.globalAlpha = 0.7
    ctx.fillStyle = fg
    ctx.font = "10px ui-monospace, SFMono-Regular, Menlo, monospace"
    ctx.textAlign = "right"
    ctx.fillText("overview · drag to move", GUTTER - 6, MINIMAP_H / 2 + 4)
    const x0 = GUTTER + (this.view[0] - d.minTs) / span * plotW, x1 = GUTTER + (this.view[1] - d.minTs) / span * plotW
    ctx.globalAlpha = 0.18
    ctx.fillRect(Math.max(x0, GUTTER), 0, Math.max(Math.min(x1, GUTTER + plotW) - Math.max(x0, GUTTER), 2), MINIMAP_H)
    ctx.globalAlpha = 0.9
    ctx.strokeStyle = fg
    ctx.lineWidth = 1
    ctx.strokeRect(Math.max(x0, GUTTER) + 0.5, 0.5, Math.max(Math.min(x1, GUTTER + plotW) - Math.max(x0, GUTTER), 2) - 1, MINIMAP_H - 1)
    ctx.globalAlpha = 1
  },

  // Where the time went: totals by phase across all actions, and per mnemonic.
  renderBreakdown() {
    if (!this.breakdown) return
    const d = this.data
    const total = Array.from(d.phaseTotals).reduce((a, b) => a + b, 0)
    if (d.actionEvent.length === 0) { this.breakdown.hidden = true; return }
    const rows = d.byMnemonic.slice(0, 12).map(m =>
      `<tr class="align-top"><td class="py-1 pr-2 font-mono"><button type="button" data-action="search" data-query="${esc(m.name)}" class="hover:underline">${esc(m.name)}</button></td>` +
      `<td class="py-1 pr-2 text-right font-mono text-base-content/70">${m.count}×</td>` +
      `<td class="py-1 pr-2 text-right font-mono">${fmtUs(m.total)}</td>` +
      `<td class="w-1/2 py-1">${phaseBarHtml(m.phases, d.phases, d.phaseColors, m.total)}</td></tr>`).join("")
    this.breakdown.hidden = false
    this.breakdown.innerHTML =
      `<h3 class="mb-1 text-sm font-semibold">Where action time went</h3>` +
      `<p class="mb-2 text-[11px] text-base-content/60">${d.actionEvent.length.toLocaleString()} actions · ${fmtUs(total)} of action time summed across threads</p>` +
      phaseBarHtml(d.phaseTotals, d.phases, d.phaseColors, total) +
      `<table class="mt-3 w-full text-xs"><thead><tr class="text-left text-[11px] text-base-content/60"><th>mnemonic</th><th class="text-right">actions</th><th class="text-right">total</th><th>breakdown</th></tr></thead><tbody>${rows}</tbody></table>`
  },

  // --- interaction ------------------------------------------------------------------------
  wheel(e) {
    if (!this.data) return
    e.preventDefault()
    const rect = this.canvas.getBoundingClientRect()
    const x = e.clientX - rect.left
    const [v0, v1] = this.view
    const range = v1 - v0
    if (e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      const dt = (e.deltaX || e.deltaY) / this.plotWidth() * range
      this.setView(v0 + dt, v1 + dt)
    } else {
      const factor = Math.exp(e.deltaY * 0.002)
      const anchor = this.tOf(Math.max(x, GUTTER))
      const newRange = range * factor
      const frac = (anchor - v0) / range
      this.setView(anchor - frac * newRange, anchor + (1 - frac) * newRange)
    }
  },

  zoomBy(factor, anchorT) {
    const [v0, v1] = this.view
    const range = v1 - v0
    const anchor = anchorT ?? (v0 + v1) / 2
    const frac = (anchor - v0) / range
    this.setView(anchor - frac * range * factor, anchor + (1 - frac) * range * factor)
  },

  pointerDown(e) {
    if (!this.data) return
    this.canvas.focus({preventScroll: true})
    const rect = this.canvas.getBoundingClientRect()
    const x = e.clientX - rect.left, y = e.clientY - rect.top
    if (x < GUTTER) return
    if (e.shiftKey || y < AXIS_H) {
      this.selecting = {t0: this.tOf(x)}
      this.selection = [this.selecting.t0, this.selecting.t0]
      return
    }
    this.dragging = {x: e.clientX, view: [...this.view], moved: false}
  },

  pointerUp() {
    if (this.selecting) {
      const [s0, s1] = this.selection
      this.selecting = null
      if (Math.abs(s1 - s0) > 0) this.setView(Math.min(s0, s1), Math.max(s0, s1))
      this.selection = null
      this.schedule()
    }
    if (this.miniDrag) this.miniDrag = null
    this.dragging = null
  },

  minimapDown(e) {
    if (!this.data) return
    const rect = this.minimap.getBoundingClientRect()
    const x = e.clientX - rect.left
    if (x < GUTTER) return
    const d = this.data
    const span = d.maxTs - d.minTs
    const t = d.minTs + (x - GUTTER) / (rect.width - GUTTER) * span
    const range = this.view[1] - this.view[0]
    if (t < this.view[0] || t > this.view[1]) this.setView(t - range / 2, t + range / 2)
    this.miniDrag = {x: e.clientX, view: [...this.view], pxSpan: rect.width - GUTTER, span}
    e.preventDefault()
  },

  mouseMove(e) {
    if (!this.data) return
    if (this.miniDrag) {
      const dt = (e.clientX - this.miniDrag.x) / this.miniDrag.pxSpan * this.miniDrag.span
      this.setView(this.miniDrag.view[0] + dt, this.miniDrag.view[1] + dt)
      return
    }
    const rect = this.canvas.getBoundingClientRect()
    const x = e.clientX - rect.left, y = e.clientY - rect.top
    if (this.selecting) {
      this.selection = [this.selecting.t0, this.tOf(Math.min(Math.max(x, GUTTER), GUTTER + this.plotWidth()))]
      this.schedule()
      return
    }
    if (this.dragging) {
      const dx = e.clientX - this.dragging.x
      if (Math.abs(dx) > 2) this.dragging.moved = true
      const dt = -dx / this.plotWidth() * (this.dragging.view[1] - this.dragging.view[0])
      this.setView(this.dragging.view[0] + dt, this.dragging.view[1] + dt)
      return
    }
    const inside = x >= 0 && y >= 0 && x <= rect.width && y <= rect.height
    this.cursorT = inside && x >= GUTTER ? this.tOf(x) : null
    const hit = inside ? this.hitTest(e) : null
    if (hit == null) { this.tooltip.hidden = true; this.schedule(); return }
    const d = this.data
    this.tooltip.hidden = false
    const bits = [d.names[d.name[hit]], fmtUs(d.dur[hit]), d.cats[d.cat[hit]]]
    if (d.phase[hit] > 0) bits.push(d.phases[d.phase[hit]])
    if (d.target[hit] >= 0) bits.push(d.targets[d.target[hit]])
    this.tooltip.textContent = bits.join(" · ")
    const box = this.el.getBoundingClientRect()
    this.tooltip.style.left = `${Math.min(e.clientX - box.left + 12, box.width - 280)}px`
    this.tooltip.style.top = `${e.clientY - box.top + 12}px`
    this.schedule()
  },

  hitTest(e) {
    const rect = this.canvas.getBoundingClientRect()
    const x = e.clientX - rect.left, y = e.clientY - rect.top
    if (x < GUTTER || y < this.topOffset()) return null
    const d = this.data
    const l = this.laneAt(y)
    if (l < 0) return null
    const rows = this.laneRows(l)
    const row = Math.min(Math.floor((y - this.laneTops()[l]) / ROW_H), rows - 1)
    const t = this.tOf(x)
    const from = d.laneOffsets[l], to = d.laneOffsets[l + 1]
    const i = lowerBound(d.ts, from, to, t)
    const minDur = (this.view[1] - this.view[0]) / this.plotWidth()
    // Candidates start at or before t; prefer the deepest one on the hovered row.
    let best = null
    for (let j = i - 1; j >= from && d.ts[j] >= t - d.laneMaxDur[l]; j--) {
      if (d.ts[j] <= t && t <= d.ts[j] + Math.max(d.dur[j], minDur)) {
        const depth = this.collapsed.has(l) ? 0 : Math.min(d.depth[j], rows - 1)
        if (this.collapsed.has(l) && d.depth[j] > 0) continue
        if (depth === row && (best == null || d.depth[j] > d.depth[best])) best = j
      }
    }
    return best
  },

  click(e) {
    if (this.dragging && this.dragging.moved) return
    const rect = this.canvas.getBoundingClientRect()
    const x = e.clientX - rect.left, y = e.clientY - rect.top
    if (x < GUTTER && y >= this.topOffset()) {
      const l = this.laneAt(y)
      if (l >= 0 && this.data.laneDepth[l] > 1) { this.collapsed.has(l) ? this.collapsed.delete(l) : this.collapsed.add(l); this.schedule() }
      return
    }
    const hit = this.hitTest(e)
    if (hit == null) return
    this.select(hit)
  },

  doubleClick(e) {
    const hit = this.hitTest(e)
    if (hit == null) this.resetView(); else this.zoomTo(hit)
  },

  key(e) {
    if (!this.data) return
    const [v0, v1] = this.view
    const range = v1 - v0
    const handled = true
    switch (e.key) {
      case "+": case "=": this.zoomBy(0.5, this.cursorT); break
      case "-": case "_": this.zoomBy(2, this.cursorT); break
      case "ArrowLeft": this.setView(v0 - range * 0.15, v1 - range * 0.15); break
      case "ArrowRight": this.setView(v0 + range * 0.15, v1 + range * 0.15); break
      case "0": case "Home": this.resetView(); break
      case "Escape": this.selection = null; this.selected = -1; if (this.details) this.details.hidden = true; this.schedule(); break
      case "/": if (this.search) { this.search.focus(); } break
      case "c": if (this.critical) { this.critical.checked = !this.critical.checked; this.critical.dispatchEvent(new Event("change")) } break
      default: return
    }
    if (handled) e.preventDefault()
  },

  // Details for one event: metadata, the action it belongs to with its phase breakdown,
  // and the longest nested events.
  select(i) {
    const d = this.data
    this.selected = i
    this.schedule()
    if (!this.details) return
    const action = d.actionOf[i]
    const rows = [
      ["Name", esc(d.names[d.name[i]])],
      ["Category", esc(d.cats[d.cat[i]])],
      ["Thread", esc(d.threads[d.lane[i]].name)],
      ["Start", fmtUs(d.ts[i] - d.minTs)],
      ["Duration", fmtUs(d.dur[i])],
    ]
    if (d.phase[i] > 0) rows.push(["Phase", esc(d.phases[d.phase[i]])])
    if (d.target[i] >= 0) rows.push(["Target", esc(d.targets[d.target[i]])])
    if (d.mnemonic[i] >= 0) rows.push(["Mnemonic", esc(d.mnemonics[d.mnemonic[i]])])
    if (d.parent[i] >= 0) rows.push(["Inside", `<button type="button" data-action="select" data-event="${d.parent[i]}" class="hover:underline">${esc(d.names[d.name[d.parent[i]]])}</button>`])
    let html = `<div class="flex flex-wrap items-center gap-2"><span class="font-semibold">Event</span><button type="button" data-action="zoom" data-event="${i}" class="rounded border border-base-300 px-2 py-0.5 hover:bg-base-200">Zoom to</button></div>` +
      rows.map(([k, v]) => `<div class="flex gap-3"><dt class="w-20 shrink-0 text-base-content/60">${k}</dt><dd class="break-all font-mono">${v}</dd></div>`).join("")
    if (action >= 0) {
      const ai = d.actionEvent[action]
      const row = d.actionPhases.slice(action * d.phases.length, (action + 1) * d.phases.length)
      html += `<div class="mt-2 border-t border-base-300 pt-2"><div class="mb-1 flex flex-wrap items-center gap-2"><span class="font-semibold">Action</span>` +
        `<span class="font-mono">${esc(d.names[d.name[ai]])}</span><span class="text-base-content/60">${fmtUs(d.dur[ai])}</span>` +
        (ai !== i ? `<button type="button" data-action="select" data-event="${ai}" class="rounded border border-base-300 px-2 py-0.5 hover:bg-base-200">Show</button>` : "") + `</div>` +
        phaseBarHtml(row, d.phases, d.phaseColors, d.dur[ai]) + `</div>`
      // Longest nested events of the action, deepest first among equals.
      const kids = []
      const from = d.laneOffsets[d.lane[ai]], to = d.laneOffsets[d.lane[ai] + 1]
      for (let j = ai + 1; j < to && d.ts[j] < d.ts[ai] + d.dur[ai]; j++) if (d.actionOf[j] === action && j !== ai) kids.push(j)
      kids.sort((a, b) => d.dur[b] - d.dur[a])
      if (kids.length) html += `<ul class="mt-2 space-y-0.5">` + kids.slice(0, 10).map(j =>
        `<li class="flex justify-between gap-2 font-mono"><button type="button" data-action="select" data-event="${j}" class="truncate text-left hover:underline">${"· ".repeat(Math.max(d.depth[j] - d.depth[ai] - 1, 0))}${esc(d.names[d.name[j]])}</button><span class="shrink-0 text-base-content/70">${fmtUs(d.dur[j])}</span></li>`).join("") + `</ul>`
    }
    this.details.hidden = false
    this.details.innerHTML = html
  },
}
