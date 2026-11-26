import {
  ContextEvent,
  ContextRecord,
  StepStat,
  cacheHitOf
} from './ContextLedger'

/**
 * One turn, opened.
 *
 * The ledger knows the money — tokens, cache, per-step wall time — but it does
 * not know what the tools were called: that lives in the local chat rows
 * (`ChatMessage.trace`, persisted with the session). This module joins the two
 * without adding a single byte to the host ledger:
 *
 *  - a step's window is `[stepEnd − stepMs, stepEnd]`, recorded by the `k:"s"`
 *    line;
 *  - a tool call belongs to the step whose window contains its start time,
 *    because every tool runs inside one step;
 *  - a turn with no timing lines gets no tool attribution at all: without the
 *    windows there is no honest place to put a call (see `hasTiming`).
 *
 * Everything here is pure so the LocalUnit suite can pin the join rules.
 */

/** One tool call as the detail page needs it (a flattened `ToolTrace`). */
export interface TraceMark {
  name: string
  /** Argument digest, already capped by the chat model. */
  input: string
  /** Result text, already capped by the chat model. */
  output: string
  /** 'in_progress' | 'completed' | 'failed'. */
  status: string
  at: number
  doneAt: number
}

/** One tool call, placed on a step. */
export interface TurnTool {
  name: string
  input: string
  output: string
  status: string
  /** Start-to-settle time; 0 while it never settled. */
  ms: number
}

/** One step of a turn: its timing, its tokens, and the tools it ran. */
export interface TurnStep {
  step: number
  /** Wall time of the step; 0 when no `k:"s"` line was recorded. */
  ms: number
  toolMs: number
  calls: number
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  reasoning: number
  context: number
  window: number
  system: number
  tools: number
  messages: number
  model: string
  time: number
  toolsUsed: TurnTool[]
}

/** Everything the detail page renders for one turn. */
export interface TurnDetail {
  turn: number
  steps: TurnStep[]
  events: ContextEvent[]
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
  cacheHit: number
  /** Occupancy after the turn finished, and the window it sat in. */
  context: number
  window: number
  /** First step start → last step end, ms; 0 when no timing is known. */
  durationMs: number
  toolCalls: number
  toolMs: number
  /** At least one local tool call was placed on a step. */
  hasTools: boolean
  /** At least one `k:"s"` timing line exists for this turn. */
  hasTiming: boolean
  /** The first step's uncached input and its cache hit; 0 when nothing settled. */
  firstInput: number
  firstHit: number
  /** False when this turn predates the ledger (or the profile has none). */
  hasLedger: boolean
}

/** Internal: a step's place in wall-clock time. */
interface Window {
  start: number
  end: number
}

/** The first step whose window contains `at`, else the nearest one. */
function stepForTime(windows: Window[], at: number): number {
  let best = -1
  let bestDistance = Number.MAX_SAFE_INTEGER
  for (let index = 0; index < windows.length; index++) {
    const window = windows[index]
    if (at >= window.start && at <= window.end) {
      return index
    }
    const distance = at < window.start ? window.start - at : at - window.end
    if (distance < bestDistance) {
      bestDistance = distance
      best = index
    }
  }
  return best
}

/** Duration of one placed tool call. */
function toolDuration(mark: TraceMark): number {
  if (mark.doneAt > mark.at) {
    return mark.doneAt - mark.at
  }
  return 0
}

/**
 * Aggregate one turn from the ledger plus the local tool traces.
 *
 * `records` must already be filtered to this session; `turn` selects the
 * subset. Steps without a settlement line (an interrupted step) are still
 * listed when a `k:"s"` line exists for them, because the timing is real even
 * when the model never answered.
 *
 * @param records - this session's settlement records.
 * @param stats - this session's step timing lines.
 * @param events - this session's window events.
 * @param marks - every local tool trace (see `Index.flattenTraces`).
 * @param turn - the turn to open.
 * @returns the detail, never null; `hasLedger` says whether anything was found.
 */
export function turnDetail(records: ContextRecord[], stats: StepStat[],
  events: ContextEvent[], marks: TraceMark[], turn: number): TurnDetail {
  const detail: TurnDetail = {
    turn: turn,
    steps: [],
    events: [],
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cacheHit: 0,
    context: 0,
    window: 0,
    durationMs: 0,
    toolCalls: 0,
    toolMs: 0,
    hasTools: false,
    hasTiming: false,
    firstInput: 0,
    firstHit: 0,
    hasLedger: false
  }

  const turnRecords: ContextRecord[] = []
  for (const record of records) {
    if (record.turn === turn) {
      turnRecords.push(record)
    }
  }
  turnRecords.sort((a: ContextRecord, b: ContextRecord) => {
    if (a.step !== b.step) {
      return a.step - b.step
    }
    return a.t - b.t
  })
  const byStep = new Map<number, StepStat>()
  for (const stat of stats) {
    if (stat.turn === turn) {
      byStep.set(stat.step, stat)
    }
  }
  for (const event of events) {
    if (event.turn === turn) {
      detail.events.push(event)
    }
  }

  // Step numbers come from either source: a step that settled but never closed
  // has tokens only, and a step that closed but never settled has timing only.
  const numbers = new Set<number>()
  for (const record of turnRecords) {
    numbers.add(record.step)
  }
  byStep.forEach((stat: StepStat, step: number) => {
    numbers.add(step)
  })
  const ordered: number[] = []
  numbers.forEach((step: number) => {
    ordered.push(step)
  })
  ordered.sort((a: number, b: number) => a - b)

  // A turn with no timing lines still needs a left edge: using the previous
  // turn's settlement keeps earlier turns' tools out of this one (an old
  // ledger has settlements but no `k:"s"` rows).
  let turnStart = 0
  for (const record of records) {
    if (record.turn < turn && record.t > turnStart) {
      turnStart = record.t
    }
  }
  const windows: Window[] = []
  let previousEnd = turnStart
  for (const step of ordered) {
    const stat = byStep.get(step)
    const record = findRecord(turnRecords, step)
    const end = stat !== undefined ? stat.t : (record !== null ? record.t : previousEnd)
    const start = stat !== undefined && stat.ms > 0 ? end - stat.ms : previousEnd
    windows.push({ start: start, end: end })
    previousEnd = end
  }

  for (let index = 0; index < ordered.length; index++) {
    const step = ordered[index]
    const stat = byStep.get(step)
    const record = findRecord(turnRecords, step)
    const value: TurnStep = {
      step: step,
      ms: stat === undefined ? 0 : stat.ms,
      toolMs: stat === undefined ? 0 : stat.tool,
      calls: stat === undefined ? 0 : stat.n,
      input: record === null ? 0 : record.inp,
      output: record === null ? 0 : record.out,
      cacheRead: record === null ? 0 : record.cr,
      cacheWrite: record === null ? 0 : record.cw,
      reasoning: record === null ? 0 : record.rs,
      context: record === null ? 0 : record.ctx,
      window: record === null ? 0 : record.win,
      system: record === null ? 0 : record.sys,
      tools: record === null ? 0 : record.tools,
      messages: record === null ? 0 : record.msg,
      model: record === null ? '' : record.m,
      time: stat !== undefined ? stat.t : (record === null ? 0 : record.t),
      toolsUsed: []
    }
    if (stat !== undefined) {
      detail.hasLedger = true
      detail.toolMs += stat.tool
    }
    if (record !== null) {
      detail.hasLedger = true
      detail.input += record.inp
      detail.output += record.out
      detail.cacheRead += record.cr
      detail.cacheWrite += record.cw
      detail.context = record.ctx
      detail.window = record.win
    }
    detail.steps.push(value)
  }

  // Without timing lines there is no honest place for a tool: an untimed turn
  // would have to claim every trace before its settlement, including the
  // previous turn's. Such a turn shows tokens and says the trajectory is not
  // attributable — better than a wrong attribution.
  detail.hasTiming = byStep.size > 0
  if (detail.hasTiming) {
    for (const mark of marks) {
      if (mark.at <= 0) {
        continue
      }
      const index = stepForTime(windows, mark.at)
      if (index < 0) {
        continue
      }
      const target = detail.steps[index]
      target.toolsUsed.push({
        name: mark.name,
        input: mark.input,
        output: mark.output,
        status: mark.status,
        ms: toolDuration(mark)
      })
      detail.hasTools = true
    }
  }

  let firstStart = 0
  let lastEnd = 0
  for (let index = 0; index < windows.length; index++) {
    if (firstStart === 0 || windows[index].start < firstStart) {
      firstStart = windows[index].start
    }
    if (windows[index].end > lastEnd) {
      lastEnd = windows[index].end
    }
  }
  // Without timing lines the windows are just settlement times: their span is
  // an absolute epoch difference, not a duration. Report "unknown" instead.
  detail.durationMs = detail.hasTiming && lastEnd > firstStart ? lastEnd - firstStart : 0
  let calls = 0
  for (const step of detail.steps) {
    calls += Math.max(step.calls, step.toolsUsed.length)
  }
  detail.toolCalls = calls
  detail.cacheHit = cacheHitOf(detail.input, detail.cacheRead, detail.cacheWrite)
  if (detail.steps.length > 0) {
    const first = detail.steps[0]
    detail.firstInput = first.input
    detail.firstHit = cacheHitOf(first.input, first.cacheRead, first.cacheWrite)
  }
  return detail
}

/** Empty detail used before the first recompute. */
export function emptyTurn(turn: number): TurnDetail {
  return {
    turn: turn,
    steps: [],
    events: [],
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cacheHit: 0,
    context: 0,
    window: 0,
    durationMs: 0,
    toolCalls: 0,
    toolMs: 0,
    hasTools: false,
    hasTiming: false,
    firstInput: 0,
    firstHit: 0,
    hasLedger: false
  }
}

/** The settlement record of one step, or null when the step never settled. */
function findRecord(records: ContextRecord[], step: number): ContextRecord | null {
  for (const record of records) {
    if (record.step === step) {
      return record
    }
  }
  return null
}
