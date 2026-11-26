/**
 * Context ledger: the native client's view of what the runtime put in the
 * window.
 *
 * The host plugin `@ohos/dsh-context-ledger` appends compact JSON lines to
 * `<filesDir>/dsh-home/context-ledger.jsonl`. Three kinds share the file:
 *
 *  - a settlement (`v:1`) per assistant message: composition, pressure,
 *    provider usage, the message split and the compaction budget;
 *  - an event (`v:2`, `k:"e"`) when the window changed for a reason worth
 *    naming: an injection, a model switch, a compaction, a prune;
 *  - a step (`v:2`, `k:"s"`) when a step closed: wall time, tool time, calls.
 *
 * ACP only forwards `usage_update` (used/size), so without this file the app
 * can show how full the window is but not where it went, whether the prefix
 * cache was hit, when the window jumped, or how long the tools took.
 *
 * Everything here is pure: parsing, per-session filtering, per-turn
 * aggregation and formatting. The panel owns rendering; this module owns the
 * numbers, which is what the host-side unit suite and LocalUnit pin.
 */

/** One committed settlement line (short keys keep the file small on a phone). */
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
  /** Message split, when the host could price the surface: the four add up to `msg`. */
  u: number
  au: number
  tr: number
  ij: number
  /** Auto-compaction threshold and the output tokens the request reserves. */
  thr: number
  rsv: number
  /** Provider usage for this settlement. */
  inp: number
  out: number
  cr: number
  cw: number
  rs: number
}

/** One "what happened" line: why the window changed, and by how much. */
export interface ContextEvent {
  t: number
  /** Session id; the host file is shared by every session it served. */
  s: string
  turn: number
  step: number
  /** `inject` / `model` / `compact` / `prune`. */
  kind: string
  /** Producer kind for an injection, model id for a switch, empty otherwise. */
  label: string
  /** Signed token delta; negative for compaction and prune. */
  d: number
}

/** One closed step: how long it took, and how much of that was tools. */
export interface StepStat {
  t: number
  /** Session id; the host file is shared by every session it served. */
  s: string
  turn: number
  step: number
  /** Wall time from step start to step end, ms. */
  ms: number
  /** Tool execution time inside that step, ms. */
  tool: number
  /** Tool calls the step made. */
  n: number
}

/** Everything one ledger file holds, already split by line kind. */
export interface LedgerData {
  records: ContextRecord[]
  events: ContextEvent[]
  steps: StepStat[]
}

/** One point of the trend chart: a settlement, its occupancy, and its delta. */
export interface ContextPoint {
  turn: number
  step: number
  context: number
  delta: number
  time: number
  /** Composition at that settlement, for the stacked trend bars. */
  system: number
  tools: number
  messages: number
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
  /** Uncached input of the turn's FIRST step, and that step's cache hit (0..1). */
  firstInput: number
  firstHit: number
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
  /**
   * Cache hit with prefix-rebuild steps left out. A step that re-sent a large
   * prompt (a build update changed the tools, a model switch, a compaction) is
   * a one-off, and letting it drag the session number makes steady state look
   * broken.
   */
  steadyHit: number
  /** Steps that re-sent ≥1k uncached input while hitting under 60%. */
  recomputes: number
  /** Uncached input those steps paid for. */
  recomputeTokens: number
  /** Steps that count toward `steadyHit`; 0 means every step was a rebuild. */
  steadySamples: number
  system: number
  tools: number
  messages: number
  /** Message split of the latest settlement; all zero when the host could not price it. */
  splitUser: number
  splitAssistant: number
  splitToolResult: number
  splitInjected: number
  /** Composition total (system + tools + messages). */
  composed: number
  context: number
  window: number
  /** Highest pressure this session reached. */
  peak: number
  /** Auto-compaction threshold and reserved output; 0 when the host did not know them. */
  threshold: number
  reserved: number
  /** Steps that recorded a timing line. */
  steps: number
  toolCalls: number
  toolMs: number
  stepMs: number
  /** Distinct turns this session has settled. */
  totalTurns: number
  /** Wall-clock span from the first settlement to the last, ms. */
  spanMs: number
  /** Settlements for the trend chart, newest last. */
  trend: ContextPoint[]
  /** Window-changing events, newest last. */
  events: ContextEvent[]
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

/** Signed finite number from a decoded object, or 0. */
function signedField(source: Record<string, Object>, key: string): number {
  const value = source[key]
  if (typeof value !== 'number') {
    return 0
  }
  const number = value as number
  return Number.isFinite(number) ? number : 0
}

/** Non-empty string from a decoded object, or ''. */
function stringField(source: Record<string, Object>, key: string): string {
  const value = source[key]
  return typeof value === 'string' ? value as string : ''
}

/** Decode one object line, or null when it is malformed or not an object. */
function objectOfLine(line: string): Record<string, Object> | null {
  try {
    const decoded = JSON.parse(line) as Object
    if (decoded === null || typeof decoded !== 'object') {
      return null
    }
    const parsed = decoded as Record<string, Object>
    // Arrays are valid JSON objects to `typeof` but never ledger rows.
    if (Array.isArray(parsed)) {
      return null
    }
    return parsed
  } catch (error) {
    return null
  }
}

/** Decode one settlement line, or null when it is malformed or from a newer schema. */
function recordOfLine(parsed: Record<string, Object>): ContextRecord | null {
  if (numberField(parsed, 'v') !== 1) {
    return null
  }
  const session = stringField(parsed, 's')
  if (session.length === 0) {
    return null
  }
  return {
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
    u: numberField(parsed, 'u'),
    au: numberField(parsed, 'au'),
    tr: numberField(parsed, 'tr'),
    ij: numberField(parsed, 'ij'),
    thr: numberField(parsed, 'thr'),
    rsv: numberField(parsed, 'rsv'),
    inp: numberField(parsed, 'inp'),
    out: numberField(parsed, 'out'),
    cr: numberField(parsed, 'cr'),
    cw: numberField(parsed, 'cw'),
    rs: numberField(parsed, 'rs')
  }
}

/** Decode one event line, or null when it is malformed. */
function eventOfLine(parsed: Record<string, Object>): ContextEvent | null {
  if (numberField(parsed, 'v') !== 2 || stringField(parsed, 's').length === 0) {
    return null
  }
  const kind = stringField(parsed, 'kind')
  if (kind.length === 0) {
    return null
  }
  return {
    t: numberField(parsed, 't'),
    s: stringField(parsed, 's'),
    turn: numberField(parsed, 'turn'),
    step: numberField(parsed, 'step'),
    kind: kind,
    label: stringField(parsed, 'label'),
    d: signedField(parsed, 'd')
  }
}

/** Decode one step line, or null when it is malformed. */
function stepOfLine(parsed: Record<string, Object>): StepStat | null {
  if (numberField(parsed, 'v') !== 2 || stringField(parsed, 's').length === 0) {
    return null
  }
  return {
    t: numberField(parsed, 't'),
    s: stringField(parsed, 's'),
    turn: numberField(parsed, 'turn'),
    step: numberField(parsed, 'step'),
    ms: numberField(parsed, 'ms'),
    tool: numberField(parsed, 'tool'),
    n: numberField(parsed, 'n')
  }
}

/**
 * Parse the whole ledger into its three line kinds, skipping blank lines, a
 * torn last line (the writer appends without a lock, so a read can catch a
 * partial record) and lines from a schema this build does not know.
 */
export function parseLedgerAll(text: string): LedgerData {
  const data: LedgerData = { records: [], events: [], steps: [] }
  if (text.length === 0) {
    return data
  }
  const lines = text.split('\n')
  for (const raw of lines) {
    const line = raw.trim()
    if (line.length === 0) {
      continue
    }
    const parsed = objectOfLine(line)
    if (parsed === null) {
      continue
    }
    const kind = stringField(parsed, 'k')
    if (kind === 'e') {
      const event = eventOfLine(parsed)
      if (event !== null) {
        data.events.push(event)
      }
    } else if (kind === 's') {
      const step = stepOfLine(parsed)
      if (step !== null) {
        data.steps.push(step)
      }
    } else {
      const record = recordOfLine(parsed)
      if (record !== null) {
        data.records.push(record)
      }
    }
  }
  return data
}

/** Settlement records only; kept for callers that do not render activity. */
export function parseLedger(text: string): ContextRecord[] {
  return parseLedgerAll(text).records
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

/**
 * The session's window-changing events, newest last.
 *
 * The host writes one file for every session it served, so the panel must
 * filter by id exactly like the settlement list does.
 */
export function eventsFor(events: ContextEvent[], sessionId: string): ContextEvent[] {
  const out: ContextEvent[] = []
  if (sessionId.length === 0) {
    return out
  }
  for (const event of events) {
    if (event.s === sessionId) {
      out.push(event)
    }
  }
  out.sort((a: ContextEvent, b: ContextEvent) => a.t - b.t)
  return out
}

/** One session's steps, in commit order; the host file is shared by sessions. */
export function stepsFor(all: StepStat[], sessionId: string): StepStat[] {
  const out: StepStat[] = []
  if (sessionId.length === 0) {
    return out
  }
  for (const step of all) {
    if (step.s === sessionId) {
      out.push(step)
    }
  }
  out.sort((a: StepStat, b: StepStat) => {
    if (a.t !== b.t) {
      return a.t < b.t ? -1 : 1
    }
    return a.step - b.step
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
  firstInput: number = -1
  firstHit: number = 0
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
    steadyHit: 0,
    recomputes: 0,
    recomputeTokens: 0,
    steadySamples: 0,
    system: 0,
    tools: 0,
    messages: 0,
    splitUser: 0,
    splitAssistant: 0,
    splitToolResult: 0,
    splitInjected: 0,
    composed: 0,
    context: 0,
    window: 0,
    peak: 0,
    totalTurns: 0,
    spanMs: 0,
    threshold: 0,
    reserved: 0,
    steps: 0,
    toolCalls: 0,
    toolMs: 0,
    stepMs: 0,
    trend: [],
    events: []
  }
}

/** Cache hit rate, 0..1; 0 when nothing was billed as input. */
export function cacheHitOf(input: number, cacheRead: number, cacheWrite: number): number {
  const total = input + cacheRead + cacheWrite
  return total > 0 ? cacheRead / total : 0
}

/** Whether one settlement re-sent its prompt instead of reusing the prefix. */
export function isRecompute(record: ContextRecord): boolean {
  return record.inp >= 1000 && cacheHitOf(record.inp, record.cr, record.cw) < 0.6
}

/** The newest `limit` settlements as trend points, each with its delta. */
export function trendOf(records: ContextRecord[], limit: number): ContextPoint[] {
  const points: ContextPoint[] = []
  for (let index = 0; index < records.length; index++) {
    const record = records[index]
    const previous = index > 0 ? records[index - 1] : null
    points.push({
      turn: record.turn,
      step: record.step,
      context: record.ctx,
      delta: previous === null ? 0 : record.ctx - previous.ctx,
      time: record.t,
      system: record.sys,
      tools: record.tools,
      messages: record.msg
    })
  }
  const from = Math.max(0, points.length - limit)
  return points.slice(from)
}

/**
 * Aggregate one session's records into the panel's numbers.
 *
 * The latest record supplies the composition and the window; per-turn rows sum
 * usage across steps (one turn can settle several assistant messages when it
 * uses tools) and keep the last step's context pressure as that turn's
 * occupancy. The newest 12 turns are kept — a phone panel is a glance, not a
 * log viewer. Events and steps are optional: an older host writes neither, and
 * the panel degrades to the settlement-only view.
 */
export function summarize(records: ContextRecord[], events: ContextEvent[] = [], steps: StepStat[] = []): ContextSummary {
  const summary = emptySummary()
  let steadyIn = 0
  let steadyCr = 0
  let steadyCw = 0
  if (records.length > 0) {
    const latest = records[records.length - 1]
    summary.records = records.length
    summary.latest = latest
    summary.system = latest.sys
    summary.tools = latest.tools
    summary.messages = latest.msg
    summary.composed = latest.sys + latest.tools + latest.msg
    summary.context = latest.ctx
    summary.window = latest.win
    summary.threshold = latest.thr
    summary.reserved = latest.rsv
    const split = latest.u + latest.au + latest.tr + latest.ij
    if (split > 0 && latest.msg > 0) {
      summary.splitUser = latest.u
      summary.splitAssistant = latest.au
      summary.splitToolResult = latest.tr
      summary.splitInjected = latest.ij
    }

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
      if (agg.firstInput < 0) {
        agg.firstInput = record.inp
        agg.firstHit = cacheHitOf(record.inp, record.cr, record.cw)
      }
      agg.model = record.m
      agg.time = record.t
      if (isRecompute(record)) {
        summary.recomputes += 1
        summary.recomputeTokens += record.inp
      } else {
        steadyIn += record.inp
        steadyCr += record.cr
        steadyCw += record.cw
        summary.steadySamples += 1
      }
      summary.totalInput += record.inp
      summary.totalOutput += record.out
      summary.totalCacheRead += record.cr
      summary.totalCacheWrite += record.cw
      summary.totalReasoning += record.rs
      summary.peak = Math.max(summary.peak, record.ctx)
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
        time: agg.time,
        firstInput: agg.firstInput < 0 ? 0 : agg.firstInput,
        firstHit: agg.firstHit
      })
    })
    turns.sort((a: ContextTurn, b: ContextTurn) => a.turn - b.turn)
    summary.totalTurns = turns.length
    summary.spanMs = Math.max(0, records[records.length - 1].t - records[0].t)
    const from = Math.max(0, turns.length - 12)
    summary.turns = turns.slice(from)
    summary.trend = trendOf(records, 24)
    summary.cacheHit = cacheHitOf(summary.totalInput, summary.totalCacheRead, summary.totalCacheWrite)
    summary.steadyHit = cacheHitOf(steadyIn, steadyCr, steadyCw)
  }

  let toolCalls = 0
  let toolMs = 0
  let stepMs = 0
  for (const step of steps) {
    toolCalls += step.n
    toolMs += step.tool
    stepMs += step.ms
  }
  summary.steps = steps.length
  summary.toolCalls = toolCalls
  summary.toolMs = toolMs
  summary.stepMs = stepMs
  const eventFrom = Math.max(0, events.length - 8)
  summary.events = events.slice(eventFrom)
  return summary
}

/** One decimal, but only when it says something: `727k` not `727.0k`. */
function compact(value: number): string {
  const rounded = Math.round(value * 10) / 10
  return Number.isInteger(rounded) ? `${rounded}` : rounded.toFixed(1)
}

/** `1234` → `1.2k`; the same scale the composer's context note uses. */
export function formatTokens(value: number): string {
  if (value >= 1000000) {
    return `${compact(value / 1000000)}M`
  }
  if (value >= 1000) {
    return `${compact(value / 1000)}k`
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

/** `93000` → `1m33s`; durations stay readable without a monospace grid. */
export function formatDuration(ms: number): string {
  if (ms <= 0) {
    return '0s'
  }
  const total = Math.round(ms / 1000)
  if (total < 60) {
    return `${total}s`
  }
  const minutes = Math.floor(total / 60)
  const seconds = total % 60
  if (minutes < 60) {
    return seconds === 0 ? `${minutes}m` : `${minutes}m${seconds}s`
  }
  const hours = Math.floor(minutes / 60)
  return `${hours}h${minutes % 60}m`
}

/** Chinese label for one ledger event kind. */
export function eventKindLabel(kind: string): string {
  if (kind === 'inject') {
    return '注入'
  }
  if (kind === 'model') {
    return '切换模型'
  }
  if (kind === 'compact') {
    return '压缩'
  }
  if (kind === 'prune') {
    return '裁掉工具结果'
  }
  return kind
}

/** Human name for the producer kind on an injection line. */
export function producerLabel(kind: string): string {
  if (kind === 'time-context') {
    return '时间上下文'
  }
  if (kind === 'instructions') {
    return '指令文件'
  }
  if (kind === 'ontology') {
    return '长期记忆'
  }
  if (kind === 'skill') {
    return '技能'
  }
  if (kind === 'goal') {
    return '目标'
  }
  return kind
}
