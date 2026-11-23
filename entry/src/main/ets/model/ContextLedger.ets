/**
 * Context ledger: the native client's view of what the runtime put in the
 * window.
 *
 * The host plugin `@ohos/dsh-context-ledger` appends one compact JSON line per
 * assistant settlement to `<filesDir>/dsh-home/context-ledger.jsonl`. ACP only
 * forwards `usage_update` (used/size), so without this file the app can show
 * how full the window is but not where it went, whether the prefix cache was
 * hit, or what the last turns cost.
 *
 * Everything here is pure: parsing, per-session filtering, per-turn
 * aggregation and formatting. The panel owns rendering; this module owns the
 * numbers, which is what the host-side unit suite pins.
 */

/** One committed ledger line (short keys keep the file small on a phone). */
export interface ContextRecord {
  /** Schema version; readers ignore anything they do not know. */
  v: number
  /** Wall clock, ms. */
  t: number
  /** Session id. */
  s: string
  turn: number
  step: number
  seq: number
  /** Provider / model that served the request. */
  p: string
  m: string
  /** Total context the next request would carry, and its window. */
  ctx: number
  win: number
  /** Composition of the current surface. */
  sys: number
  tools: number
  msg: number
  /** Provider usage for this settlement. */
  inp: number
  out: number
  cr: number
  cw: number
  rs: number
}

/** One turn, summed across its steps; `context` is the last step's pressure. */
export interface ContextTurn {
  turn: number
  steps: number
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  reasoning: number
  context: number
  window: number
  model: string
  time: number
}

/** Everything the panel renders for one session. */
export interface ContextSummary {
  records: number
  latest: ContextRecord | null
  turns: ContextTurn[]
  totalInput: number
  totalOutput: number
  totalCacheRead: number
  totalCacheWrite: number
  totalReasoning: number
  /** 0..1; cacheRead / (uncached input + cacheRead + cacheWrite). */
  cacheHit: number
  system: number
  tools: number
  messages: number
  /** Composition total (system + tools + messages). */
  composed: number
  context: number
  window: number
}

/** Finite non-negative number from a decoded object, or 0. */
function numberField(source: Record<string, Object>, key: string): number {
  const value = source[key]
  if (typeof value !== 'number') {
    return 0
  }
  const number = value as number
  return Number.isFinite(number) && number > 0 ? number : 0
}

/** Non-empty string from a decoded object, or ''. */
function stringField(source: Record<string, Object>, key: string): string {
  const value = source[key]
  return typeof value === 'string' ? value as string : ''
}

/** Decode one line, or null when it is malformed or from a newer schema. */
function recordOfLine(line: string): ContextRecord | null {
  let parsed: Record<string, Object>
  try {
    const decoded = JSON.parse(line) as Object
    if (decoded === null || typeof decoded !== 'object') {
      return null
    }
    parsed = decoded as Record<string, Object>
  } catch (error) {
    return null
  }
  if (numberField(parsed, 'v') !== 1) {
    return null
  }
  const session = stringField(parsed, 's')
  if (session.length === 0) {
    return null
  }
  const record: ContextRecord = {
    v: 1,
    t: numberField(parsed, 't'),
    s: session,
    turn: numberField(parsed, 'turn'),
    step: numberField(parsed, 'step'),
    seq: numberField(parsed, 'seq'),
    p: stringField(parsed, 'p'),
    m: stringField(parsed, 'm'),
    ctx: numberField(parsed, 'ctx'),
    win: numberField(parsed, 'win'),
    sys: numberField(parsed, 'sys'),
    tools: numberField(parsed, 'tools'),
    msg: numberField(parsed, 'msg'),
    inp: numberField(parsed, 'inp'),
    out: numberField(parsed, 'out'),
    cr: numberField(parsed, 'cr'),
    cw: numberField(parsed, 'cw'),
    rs: numberField(parsed, 'rs')
  }
  return record
}

/**
 * Parse the whole ledger, skipping blank lines, a torn last line (the writer
 * appends without a lock, so a read can catch a partial record) and records
 * from a schema this build does not know.
 */
export function parseLedger(text: string): ContextRecord[] {
  const out: ContextRecord[] = []
  if (text.length === 0) {
    return out
  }
  const lines = text.split('\n')
  for (const raw of lines) {
    const line = raw.trim()
    if (line.length === 0) {
      continue
    }
    const record = recordOfLine(line)
    if (record !== null) {
      out.push(record)
    }
  }
  return out
}

/** Records belonging to one session, in commit order. */
export function recordsFor(records: ContextRecord[], sessionId: string): ContextRecord[] {
  const out: ContextRecord[] = []
  for (const record of records) {
    if (record.s === sessionId) {
      out.push(record)
    }
  }
  out.sort((a: ContextRecord, b: ContextRecord) => {
    if (a.t !== b.t) {
      return a.t < b.t ? -1 : 1
    }
    return a.seq - b.seq
  })
  return out
}

/** Internal mutable turn accumulator. */
class TurnAgg {
  turn: number = 0
  steps: number = 0
  input: number = 0
  output: number = 0
  cacheRead: number = 0
  cacheWrite: number = 0
  reasoning: number = 0
  context: number = 0
  window: number = 0
  model: string = ''
  time: number = 0
}

/** Empty summary for the no-data state. */
export function emptySummary(): ContextSummary {
  return {
    records: 0,
    latest: null,
    turns: [],
    totalInput: 0,
    totalOutput: 0,
    totalCacheRead: 0,
    totalCacheWrite: 0,
    totalReasoning: 0,
    cacheHit: 0,
    system: 0,
    tools: 0,
    messages: 0,
    composed: 0,
    context: 0,
    window: 0
  }
}

/** Cache hit rate, 0..1; 0 when nothing was billed as input. */
export function cacheHitOf(input: number, cacheRead: number, cacheWrite: number): number {
  const total = input + cacheRead + cacheWrite
  return total > 0 ? cacheRead / total : 0
}

/**
 * Aggregate one session's records into the panel's numbers.
 *
 * The latest record supplies the composition and the window; per-turn rows sum
 * usage across steps (one turn can settle several assistant messages when it
 * uses tools) and keep the last step's context pressure as that turn's
 * occupancy. The newest 12 turns are kept — a phone panel is a glance, not a
 * log viewer.
 */
export function summarize(records: ContextRecord[]): ContextSummary {
  if (records.length === 0) {
    return emptySummary()
  }
  const summary = emptySummary()
  const latest = records[records.length - 1]
  summary.records = records.length
  summary.latest = latest
  summary.system = latest.sys
  summary.tools = latest.tools
  summary.messages = latest.msg
  summary.composed = latest.sys + latest.tools + latest.msg
  summary.context = latest.ctx
  summary.window = latest.win

  const byTurn = new Map<number, TurnAgg>()
  for (const record of records) {
    let agg = byTurn.get(record.turn)
    if (agg === undefined) {
      agg = new TurnAgg()
      agg.turn = record.turn
      byTurn.set(record.turn, agg)
    }
    agg.steps += 1
    agg.input += record.inp
    agg.output += record.out
    agg.cacheRead += record.cr
    agg.cacheWrite += record.cw
    agg.reasoning += record.rs
    agg.context = record.ctx
    agg.window = record.win
    agg.model = record.m
    agg.time = record.t
    summary.totalInput += record.inp
    summary.totalOutput += record.out
    summary.totalCacheRead += record.cr
    summary.totalCacheWrite += record.cw
    summary.totalReasoning += record.rs
  }

  const turns: ContextTurn[] = []
  byTurn.forEach((agg: TurnAgg) => {
    turns.push({
      turn: agg.turn,
      steps: agg.steps,
      input: agg.input,
      output: agg.output,
      cacheRead: agg.cacheRead,
      cacheWrite: agg.cacheWrite,
      reasoning: agg.reasoning,
      context: agg.context,
      window: agg.window,
      model: agg.model,
      time: agg.time
    })
  })
  turns.sort((a: ContextTurn, b: ContextTurn) => a.turn - b.turn)
  const from = Math.max(0, turns.length - 12)
  summary.turns = turns.slice(from)
  summary.cacheHit = cacheHitOf(summary.totalInput, summary.totalCacheRead, summary.totalCacheWrite)
  return summary
}

/** `1234` → `1.2k`; the same scale the composer's context note uses. */
export function formatTokens(value: number): string {
  if (value >= 1000000) {
    return `${(value / 1000000).toFixed(1)}M`
  }
  if (value >= 1000) {
    return `${(value / 1000).toFixed(1)}k`
  }
  return `${Math.round(value)}`
}

/** Percent 0..100, rounded; 0 when the denominator is unknown. */
export function percentOf(part: number, total: number): number {
  if (total <= 0) {
    return 0
  }
  return Math.max(0, Math.min(100, Math.round((part / total) * 100)))
}

/** Short model label for a turn row: `deepseek-v4-flash` → `v4-flash`. */
export function shortModel(model: string): string {
  const trimmed = model.trim()
  if (trimmed.length === 0) {
    return ''
  }
  const index = trimmed.indexOf('-')
  return index >= 0 ? trimmed.substring(index + 1) : trimmed
}
