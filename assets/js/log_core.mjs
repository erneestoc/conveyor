// Build-log engine shared by the log Web Worker and its in-page fallback.
//
// The log is kept as UTF-8 bytes in fixed-size pages plus an array of line start offsets,
// so a multi-hundred-megabyte log costs about its own size in memory and never becomes one
// giant JavaScript string. Terminal behaviour is emulated as bytes arrive: "\r" rewinds the
// current line, ESC[nA (cursor up) discards the previous n lines, ESC[K / ESC[J are ignored
// and SGR colour sequences (ESC[...m) are kept for the renderer. Only the tail of the buffer
// ever changes, so line numbers of everything above it are stable.

const PAGE = 1 << 22 // 4 MiB

export class LogBuffer {
  constructor() {
    this.pages = []
    this.length = 0
    this.lineStarts = new Uint32Array(4096)
    this.lineCount = 0 // completed lines; lineStarts[lineCount] is the start of the partial line
    this.rawBytes = 0 // input bytes consumed, for splicing live appends by offset
    this.pending = null // incomplete escape sequence or lone "\r" carried to the next chunk
    this.decoder = new TextDecoder()
  }

  // Number of lines to display: completed lines plus a non-empty partial line.
  lines() {
    return this.lineCount + (this.length > this.lineStarts[this.lineCount] ? 1 : 0)
  }

  feed(chunk) {
    this.rawBytes += chunk.length
    if (this.pending) {
      const joined = new Uint8Array(this.pending.length + chunk.length)
      joined.set(this.pending, 0)
      joined.set(chunk, this.pending.length)
      chunk = joined
      this.pending = null
    }
    const n = chunk.length
    let i = 0
    let runStart = 0 // plain bytes not yet copied
    const flush = (to) => { if (to > runStart) this.write(chunk, runStart, to) }
    while (i < n) {
      const b = chunk[i]
      if (b === 0x0a) {
        flush(i)
        this.write(chunk, i, i + 1)
        this.newline()
        i++
        runStart = i
      } else if (b === 0x0d) {
        flush(i)
        if (i + 1 >= n) { this.pending = chunk.subarray(i); return }
        if (chunk[i + 1] !== 0x0a) this.truncate(this.lineStarts[this.lineCount])
        i++
        runStart = i
      } else if (b === 0x1b) {
        flush(i)
        if (i + 1 >= n) { this.pending = chunk.subarray(i); return }
        if (chunk[i + 1] !== 0x5b) { i++; runStart = i; continue } // lone ESC: dropped
        let j = i + 2
        while (j < n && ((chunk[j] >= 0x30 && chunk[j] <= 0x3f))) j++
        if (j >= n) { this.pending = chunk.subarray(i); return }
        const final = chunk[j]
        if (final === 0x6d) { // "m": keep SGR for the renderer
          this.write(chunk, i, j + 1)
        } else if (final === 0x41) { // "A": cursor up n lines
          let count = 0
          for (let k = i + 2; k < j; k++) { const d = chunk[k] - 0x30; if (d >= 0 && d <= 9) count = count * 10 + d }
          this.cursorUp(count || 1)
        }
        i = j + 1
        runStart = i
      } else {
        i++
      }
    }
    flush(n)
  }

  newline() {
    this.lineCount++
    if (this.lineCount >= this.lineStarts.length) {
      const bigger = new Uint32Array(this.lineStarts.length * 2)
      bigger.set(this.lineStarts)
      this.lineStarts = bigger
    }
    this.lineStarts[this.lineCount] = this.length
  }

  cursorUp(count) {
    this.truncate(this.lineStarts[this.lineCount])
    for (let k = 0; k < count && this.lineCount > 0; k++) {
      this.lineCount--
      this.truncate(this.lineStarts[this.lineCount])
    }
  }

  write(src, from, to) {
    let pos = this.length
    while (from < to) {
      const pageIndex = Math.floor(pos / PAGE)
      if (pageIndex >= this.pages.length) this.pages.push(new Uint8Array(PAGE))
      const offset = pos % PAGE
      const take = Math.min(PAGE - offset, to - from)
      this.pages[pageIndex].set(src.subarray(from, from + take), offset)
      from += take
      pos += take
    }
    this.length = pos
  }

  truncate(to) {
    this.length = to
    const keep = Math.ceil(to / PAGE) || (to === 0 ? 0 : 1)
    if (this.pages.length > keep + 1) this.pages.length = keep + 1
  }

  bytes(from, to) {
    if (to <= from) return new Uint8Array(0)
    const firstPage = Math.floor(from / PAGE)
    if (Math.floor((to - 1) / PAGE) === firstPage) return this.pages[firstPage].subarray(from % PAGE, from % PAGE + (to - from))
    const out = new Uint8Array(to - from)
    let pos = from
    while (pos < to) {
      const pageIndex = Math.floor(pos / PAGE)
      const offset = pos % PAGE
      const take = Math.min(PAGE - offset, to - pos)
      out.set(this.pages[pageIndex].subarray(offset, offset + take), pos - from)
      pos += take
    }
    return out
  }

  // Text of 0-based line `i` (without its newline).
  line(i) {
    if (i < 0 || i >= this.lines()) return ""
    const start = this.lineStarts[i]
    const end = i < this.lineCount ? this.lineStarts[i + 1] - 1 : this.length
    return this.decoder.decode(this.bytes(start, end))
  }
}

// Case-insensitive substring search over lines [from, to), returning matching 0-based indexes.
export function scan(buffer, query, from, to, out) {
  const q = query.toLowerCase()
  for (let i = from; i < to; i++) if (buffer.line(i).toLowerCase().includes(q)) out.push(i)
  return out
}

// Message-driven engine used by the worker (and in-page when workers are unavailable).
// post(message) delivers results; messages: load, append, lines, filter.
export function createLogEngine(post, fetchImpl = globalThis.fetch) {
  let buffer = new LogBuffer()
  let loading = true // appends before the first load are queued, not spliced
  let generation = 0
  let queued = []
  let filter = null // {query, matches: number[], scanned}
  const encoder = new TextEncoder()

  const count = (extra = {}) =>
    post({type: "count", lines: buffer.lines(), bytes: buffer.rawBytes, loading, matches: filter ? filter.matches.length : null, ...extra})

  const rescan = () => {
    if (!filter) return
    const lines = buffer.lines()
    // Lines above the tail are stable; only what changed since the last scan is rescanned.
    while (filter.matches.length > 0 && filter.matches[filter.matches.length - 1] >= Math.min(filter.scanned, lines) - 1) filter.matches.pop()
    scan(buffer, filter.query, Math.max(0, Math.min(filter.scanned, lines) - 1), lines, filter.matches)
    filter.scanned = lines
    post({type: "filter", query: filter.query, matches: Uint32Array.from(filter.matches)})
  }

  // Applies queued appends that continue the buffer, in offset order; anything already
  // covered is dropped, anything beyond the end (not yet committed on the server when we
  // loaded, or lost on a socket reconnect) stays queued. Returns whether a gap remains.
  const splice = () => {
    queued.sort((a, b) => a.offset - b.offset)
    const rest = []
    for (const q of queued) {
      if (q.offset > buffer.rawBytes) rest.push(q)
      else if (q.offset + q.bytes.length > buffer.rawBytes) buffer.feed(q.bytes.subarray(buffer.rawBytes - q.offset))
    }
    queued = rest.slice(-1000)
    return rest.length > 0
  }

  const load = async (url) => {
    const gen = ++generation
    buffer = new LogBuffer()
    filter = filter && {query: filter.query, matches: [], scanned: 0}
    loading = true
    count()
    try {
      const response = await fetchImpl(url, {credentials: "same-origin"})
      if (!response.ok) throw new Error(`log fetch failed: ${response.status}`)
      const reader = response.body.getReader()
      let lastReport = 0
      for (;;) {
        const {done, value} = await reader.read()
        if (gen !== generation) return
        if (done) break
        buffer.feed(value)
        if (buffer.rawBytes - lastReport > 2 * 1024 * 1024) { lastReport = buffer.rawBytes; count() }
      }
      loading = false
      if (splice()) post({type: "gap"})
      rescan()
      count()
    } catch (error) {
      loading = false
      post({type: "error", message: String(error && error.message || error)})
    }
  }

  return (message) => {
    switch (message.type) {
      case "load":
        load(message.url)
        break
      case "append":
        queued.push({bytes: encoder.encode(message.text), offset: message.offset})
        if (!loading) {
          if (splice()) post({type: "gap"})
          rescan()
          count()
        }
        break
      case "lines": {
        const numbers = message.numbers
        const texts = new Array(numbers.length)
        for (let i = 0; i < numbers.length; i++) texts[i] = buffer.line(numbers[i] - 1)
        post({type: "lines", req: message.req, numbers, texts})
        break
      }
      case "filter":
        if (message.query) { filter = {query: message.query, matches: [], scanned: 0}; rescan() }
        else { filter = null; post({type: "filter", query: "", matches: new Uint32Array(0)}) }
        count()
        break
    }
  }
}
