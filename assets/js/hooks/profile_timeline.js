// Canvas flame-style timeline for Bazel JSON profiles. A Web Worker fetches and parses the
// profile; this hook draws one lane per thread with zoom (wheel), pan (drag), hover
// tooltips, click details, search, category filter and a critical-path toggle. Only the
// visible time range is drawn and events narrower than a pixel are coalesced, so profiles
// with hundreds of thousands of events stay smooth.
const ROW_H = 18
const GUTTER = 220
const AXIS_H = 22
const COUNTER_H = 48
const PALETTE = ["#3b82f6", "#10b981", "#f59e0b", "#8b5cf6", "#ec4899", "#14b8a6", "#f97316", "#6366f1", "#84cc16", "#06b6d4", "#a855f7", "#ef4444"]

function fmtUs(us) {
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

export const ProfileTimeline = {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.scroller = this.el.querySelector("[data-role=scroller]")
    this.status = this.el.querySelector("[data-role=status]")
    this.tooltip = this.el.querySelector("[data-role=tooltip]")
    this.details = this.el.querySelector("[data-role=details]")
    this.search = this.el.querySelector("[data-role=search]")
    this.category = this.el.querySelector("[data-role=category]")
    this.critical = this.el.querySelector("[data-role=critical]")
    this.reset = this.el.querySelector("[data-role=reset]")
    this.ctx = this.canvas.getContext("2d")
    this.filter = ""
    this.catFilter = -1
    this.critOnly = false
    this.raf = null

    this.setStatus("Loading profile…")
    this.worker = new Worker(this.el.dataset.worker)
    this.worker.onmessage = ({data}) => {
      if (!data.ok) { this.setStatus(`Could not load the profile: ${data.error}`); return }
      this.data = data
      this.view = [data.minTs, Math.max(data.maxTs, data.minTs + 1)]
      this.fillCategories()
      this.setStatus(`${data.eventCount.toLocaleString()} events · ${data.threads.length} threads · ${fmtUs(data.maxTs - data.minTs)}`)
      this.el.dataset.loaded = "true"
      this.schedule()
    }
    this.worker.onerror = e => this.setStatus(`Could not load the profile: ${e.message || "worker error"}`)
    this.worker.postMessage({url: this.el.dataset.url})

    this.onWheel = e => this.wheel(e)
    this.onDown = e => this.dragStart(e)
    this.onMove = e => this.mouseMove(e)
    this.onUp = () => { this.dragging = null }
    this.onLeave = () => { this.tooltip.hidden = true }
    this.onClick = e => this.click(e)
    this.onResize = () => this.schedule()
    this.canvas.addEventListener("wheel", this.onWheel, {passive: false})
    this.canvas.addEventListener("mousedown", this.onDown)
    window.addEventListener("mousemove", this.onMove)
    window.addEventListener("mouseup", this.onUp)
    this.canvas.addEventListener("mouseleave", this.onLeave)
    this.canvas.addEventListener("click", this.onClick)
    this.canvas.addEventListener("dblclick", () => this.resetView())
    window.addEventListener("resize", this.onResize)
    if (this.search) this.search.addEventListener("input", () => { this.filter = this.search.value.trim().toLowerCase(); this.schedule() })
    if (this.category) this.category.addEventListener("change", () => { this.catFilter = parseInt(this.category.value, 10); this.schedule() })
    if (this.critical) this.critical.addEventListener("change", () => { this.critOnly = this.critical.checked; this.schedule() })
    if (this.reset) this.reset.addEventListener("click", () => this.resetView())
  },

  destroyed() {
    if (this.worker) this.worker.terminate()
    if (this.raf) cancelAnimationFrame(this.raf)
    window.removeEventListener("mousemove", this.onMove)
    window.removeEventListener("mouseup", this.onUp)
    window.removeEventListener("resize", this.onResize)
  },

  setStatus(text) { if (this.status) this.status.textContent = text },

  fillCategories() {
    if (!this.category) return
    const cats = this.data.cats.map((c, i) => [c, i]).sort((a, b) => a[0].localeCompare(b[0]))
    this.category.innerHTML = `<option value="-1">All categories</option>` +
      cats.map(([c, i]) => `<option value="${i}">${c.replace(/</g, "&lt;")}</option>`).join("")
  },

  resetView() { if (this.data) { this.view = [this.data.minTs, Math.max(this.data.maxTs, this.data.minTs + 1)]; this.schedule() } },

  schedule() { if (!this.raf) this.raf = requestAnimationFrame(() => { this.raf = null; this.render() }) },

  // --- geometry ---------------------------------------------------------------------------
  plotWidth() { return Math.max(this.canvas.clientWidth - GUTTER, 50) },
  counterHeight() { return this.data && this.data.counters.length ? COUNTER_H : 0 },
  topOffset() { return AXIS_H + this.counterHeight() },
  xOf(t) { return GUTTER + (t - this.view[0]) / (this.view[1] - this.view[0]) * this.plotWidth() },
  tOf(x) { return this.view[0] + (x - GUTTER) / this.plotWidth() * (this.view[1] - this.view[0]) },

  visible(i) {
    const d = this.data
    if (this.critOnly && d.cat[i] !== d.critCat) return false
    if (this.catFilter >= 0 && d.cat[i] !== this.catFilter) return false
    if (this.filter) {
      const n = d.names[d.name[i]].toLowerCase()
      if (n.includes(this.filter)) return true
      const a = d.arg[i] >= 0 ? d.args[d.arg[i]].toLowerCase() : ""
      return a.includes(this.filter)
    }
    return true
  },

  // --- drawing ----------------------------------------------------------------------------
  render() {
    if (!this.data) return
    const d = this.data
    const dpr = window.devicePixelRatio || 1
    const width = this.el.clientWidth
    const height = this.topOffset() + d.threads.length * ROW_H
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
        ctx.fillText(`${c.name} (${key}) max ${max}`, GUTTER - 6, y0 + h - 4)
        ctx.globalAlpha = 1
      })
    }

    // Lanes
    const top = this.topOffset()
    const filtering = this.filter || this.catFilter >= 0 || this.critOnly
    for (let l = 0; l < d.threads.length; l++) {
      const y = top + l * ROW_H
      ctx.fillStyle = fg
      ctx.globalAlpha = l % 2 ? 0.04 : 0
      ctx.fillRect(0, y, width, ROW_H)
      ctx.globalAlpha = 0.75
      ctx.textAlign = "right"
      ctx.fillText(d.threads[l].name.length > 30 ? d.threads[l].name.slice(0, 29) + "…" : d.threads[l].name, GUTTER - 6, y + 13)
      ctx.globalAlpha = 1

      const from = d.laneOffsets[l], to = d.laneOffsets[l + 1]
      if (from === to) continue
      let i = lowerBound(d.ts, from, to, v0 - d.laneMaxDur[l])
      let lastX = -Infinity
      for (; i < to; i++) {
        const t0 = d.ts[i]
        if (t0 > v1) break
        const t1 = t0 + d.dur[i]
        if (t1 < v0) continue
        const x0 = Math.max(this.xOf(t0), GUTTER)
        const x1 = Math.min(this.xOf(t1), GUTTER + plotW)
        const w = Math.max(x1 - x0, 1)
        if (x0 + w <= lastX + 0.5) continue
        lastX = x0 + w
        const vis = !filtering || this.visible(i)
        ctx.globalAlpha = vis ? 1 : 0.12
        ctx.fillStyle = d.cat[i] === d.critCat ? "#ef4444" : PALETTE[d.cat[i] % PALETTE.length]
        ctx.fillRect(x0, y + 3, w, ROW_H - 6)
        if (w > 30 && vis) {
          ctx.fillStyle = "#fff"
          ctx.textAlign = "left"
          const label = d.names[d.name[i]]
          const maxChars = Math.floor((w - 6) / 6.5)
          ctx.fillText(label.length > maxChars ? label.slice(0, Math.max(maxChars - 1, 0)) + "…" : label, x0 + 3, y + 13)
        }
      }
      ctx.globalAlpha = 1
    }
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
      this.view = [v0 + dt, v1 + dt]
    } else {
      const factor = Math.exp(e.deltaY * 0.002)
      const anchor = this.tOf(Math.max(x, GUTTER))
      const newRange = Math.min(Math.max(range * factor, 20), (this.data.maxTs - this.data.minTs) * 2 || 1)
      const frac = (anchor - v0) / range
      this.view = [anchor - frac * newRange, anchor + (1 - frac) * newRange]
    }
    this.schedule()
  },

  dragStart(e) {
    if (!this.data) return
    this.dragging = {x: e.clientX, view: [...this.view], moved: false}
  },

  mouseMove(e) {
    if (!this.data) return
    if (this.dragging) {
      const dx = e.clientX - this.dragging.x
      if (Math.abs(dx) > 2) this.dragging.moved = true
      const dt = -dx / this.plotWidth() * (this.dragging.view[1] - this.dragging.view[0])
      this.view = [this.dragging.view[0] + dt, this.dragging.view[1] + dt]
      this.schedule()
      return
    }
    const hit = this.hitTest(e)
    if (!hit) { this.tooltip.hidden = true; return }
    const d = this.data
    this.tooltip.hidden = false
    this.tooltip.textContent = `${d.names[d.name[hit]]} · ${fmtUs(d.dur[hit])} · ${d.cats[d.cat[hit]]}`
    const rect = this.el.getBoundingClientRect()
    this.tooltip.style.left = `${Math.min(e.clientX - rect.left + 12, rect.width - 260)}px`
    this.tooltip.style.top = `${e.clientY - rect.top + 12}px`
  },

  hitTest(e) {
    const rect = this.canvas.getBoundingClientRect()
    const x = e.clientX - rect.left, y = e.clientY - rect.top
    if (x < GUTTER || y < this.topOffset()) return null
    const d = this.data
    const l = Math.floor((y - this.topOffset()) / ROW_H)
    if (l < 0 || l >= d.threads.length) return null
    const t = this.tOf(x)
    const from = d.laneOffsets[l], to = d.laneOffsets[l + 1]
    let i = lowerBound(d.ts, from, to, t)
    // The event containing t starts at or before t; scan back within the lane's max duration.
    for (let j = i - 1; j >= from && d.ts[j] >= t - d.laneMaxDur[l]; j--) {
      if (d.ts[j] <= t && t <= d.ts[j] + Math.max(d.dur[j], (this.view[1] - this.view[0]) / this.plotWidth())) return j
    }
    return null
  },

  click(e) {
    if (this.dragging && this.dragging.moved) return
    const hit = this.hitTest(e)
    if (hit == null || !this.details) return
    const d = this.data
    const rows = [
      ["Name", d.names[d.name[hit]]],
      ["Category", d.cats[d.cat[hit]]],
      ["Thread", d.threads[d.lane[hit]].name],
      ["Start", fmtUs(d.ts[hit] - d.minTs)],
      ["Duration", fmtUs(d.dur[hit])],
    ]
    if (d.arg[hit] >= 0) rows.push(["Args", d.args[d.arg[hit]]])
    this.details.hidden = false
    this.details.innerHTML = rows.map(([k, v]) => `<div class="flex gap-3"><dt class="w-20 shrink-0 text-base-content/60">${k}</dt><dd class="break-all font-mono">${String(v).replace(/&/g, "&amp;").replace(/</g, "&lt;")}</dd></div>`).join("")
  },
}
