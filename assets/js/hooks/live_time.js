// Keeps durations of in-progress builds ticking and relative timestamps fresh without
// server round-trips. Elements carry data-started (ISO 8601) and optionally data-finished.
const pad = n => (n < 10 ? "0" + n : "" + n)

export function formatDuration(ms) {
  if (ms < 0) ms = 0
  if (ms < 1000) return `${Math.round(ms)}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  if (ms < 3600000) return `${Math.floor(ms / 60000)}m ${pad(Math.floor((ms % 60000) / 1000))}s`
  return `${Math.floor(ms / 3600000)}h ${pad(Math.floor((ms % 3600000) / 60000))}m`
}

export function formatRelative(date, now) {
  const seconds = Math.floor((now - date) / 1000)
  if (seconds < 60) return "just now"
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  if (seconds < 172800) return "yesterday"
  if (seconds < 30 * 86400) return `${Math.floor(seconds / 86400)}d ago`
  return date.toISOString().slice(0, 10)
}

const tick = el => {
  const started = el.dataset.started && new Date(el.dataset.started)
  if (!started) return
  if (el.dataset.mode === "relative") {
    el.textContent = formatRelative(started, Date.now())
  } else if (!el.dataset.finished) {
    el.textContent = formatDuration(Date.now() - started.getTime())
  }
}

export const LiveTime = {
  mounted() {
    tick(this.el)
    this.timer = setInterval(() => tick(this.el), 1000)
  },
  updated() {
    tick(this.el)
  },
  destroyed() {
    clearInterval(this.timer)
  },
}
