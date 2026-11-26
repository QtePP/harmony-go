import { describe, it, expect } from '@ohos/hypium'
import {
  ContextEvent,
  ContextRecord,
  StepStat,
  parseLedgerAll
} from '../main/ets/model/ContextLedger'
import { TraceMark, emptyTurn, turnDetail } from '../main/ets/model/TurnDetail'

/**
 * The per-turn receipt: ledger numbers joined with local tool traces.
 *
 * The join is by wall clock (a step's window is `[end − ms, end]`), so the
 * cases worth pinning are the ones a real session produces: several steps in
 * one turn, a tool whose start lands between two windows, an interrupted step
 * that has timing but no settlement, and a turn the ledger never recorded.
 */

function record(turn: number, step: number, time: number, input: number, output: number,
  cacheRead: number, cacheWrite: number, context: number, window: number): string {
  return JSON.stringify({
    v: 1, t: time, s: 's-1', turn: turn, step: step, seq: step, p: 'deepseek-official',
    m: 'deepseek-v4-flash', ctx: context, win: window, sys: 100, tools: 500, msg: 300,
    u: 0, au: 0, tr: 0, ij: 0, thr: 0, rsv: 0,
    inp: input, out: output, cr: cacheRead, cw: cacheWrite, rs: 0
  })
}

function stepLine(turn: number, step: number, time: number, ms: number, tool: number, n: number): string {
  return JSON.stringify({ v: 2, k: 's', t: time, s: 's-1', turn: turn, step: step, ms: ms, tool: tool, n: n })
}

function eventLine(turn: number, time: number, kind: string, label: string, delta: number): string {
  return JSON.stringify({
    v: 2, k: 'e', t: time, s: 's-1', turn: turn, step: 1, kind: kind, label: label, d: delta
  })
}

function mark(name: string, at: number, doneAt: number, status: string): TraceMark {
  return { name: name, input: '{"pattern":"*"}', output: 'ok', status: status, at: at, doneAt: doneAt }
}

export default function turnDetailTest() {
  describe('TurnDetail / aggregate', () => {
    it('sums a turn across steps and keeps the last occupancy', 0, () => {
      const data = parseLedgerAll([
        record(2, 1, 1000, 100, 20, 800, 0, 5000, 100000),
        stepLine(2, 1, 1000, 400, 100, 1),
        record(2, 2, 2000, 50, 10, 900, 10, 6000, 100000),
        stepLine(2, 2, 2000, 600, 0, 0),
        record(3, 1, 3000, 1, 1, 1, 1, 7000, 100000)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [], 2)
      expect(detail.hasLedger).assertTrue()
      expect(detail.steps.length).assertEqual(2)
      expect(detail.input).assertEqual(150)
      expect(detail.output).assertEqual(30)
      expect(detail.cacheRead).assertEqual(1700)
      expect(detail.cacheWrite).assertEqual(10)
      expect(detail.context).assertEqual(6000)
      expect(detail.window).assertEqual(100000)
      expect(detail.toolCalls).assertEqual(1)
      expect(detail.toolMs).assertEqual(100)
      // First step starts at 600, last ends at 2000.
      expect(detail.durationMs).assertEqual(1400)
      expect(detail.cacheHit > 0.9).assertTrue()
      expect(detail.firstInput).assertEqual(100)
      expect(detail.firstHit > 0.85).assertTrue()
    })

    it('lists a step that has timing but no settlement', 0, () => {
      const data = parseLedgerAll([
        record(1, 1, 1000, 10, 10, 10, 0, 1000, 100000),
        stepLine(1, 1, 1000, 300, 0, 0),
        stepLine(1, 2, 1500, 200, 50, 1)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [], 1)
      expect(detail.steps.length).assertEqual(2)
      expect(detail.steps[1].ms).assertEqual(200)
      expect(detail.steps[1].input).assertEqual(0)
    })

    it('keeps only this turn\'s events', 0, () => {
      const data = parseLedgerAll([
        record(1, 1, 1000, 10, 10, 10, 0, 1000, 100000),
        eventLine(1, 900, 'inject', 'time-context', 70),
        eventLine(2, 1900, 'model', 'deepseek-v4-pro', 0)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [], 1)
      expect(detail.events.length).assertEqual(1)
      expect(detail.events[0].label).assertEqual('time-context')
    })

    it('returns an empty detail for a turn the ledger never saw', 0, () => {
      const detail = turnDetail([], [], [], [mark('glob', 100, 200, 'completed')], 9)
      expect(detail.hasLedger).assertFalse()
      expect(detail.steps.length).assertEqual(0)
      expect(detail.hasTools).assertFalse()
      expect(emptyTurn(9).turn).assertEqual(9)
    })
  })

  describe('TurnDetail / tool join', () => {
    it('places each tool on the step whose window contains it', 0, () => {
      const data = parseLedgerAll([
        record(1, 1, 1000, 10, 10, 10, 0, 1000, 100000),
        stepLine(1, 1, 1000, 400, 100, 1),
        record(1, 2, 2000, 10, 10, 10, 0, 1000, 100000),
        stepLine(1, 2, 2000, 400, 100, 1)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [
        mark('glob', 700, 800, 'completed'),
        mark('read', 1700, 1900, 'failed')
      ], 1)
      expect(detail.hasTools).assertTrue()
      expect(detail.steps[0].toolsUsed.length).assertEqual(1)
      expect(detail.steps[0].toolsUsed[0].name).assertEqual('glob')
      expect(detail.steps[0].toolsUsed[0].ms).assertEqual(100)
      expect(detail.steps[1].toolsUsed.length).assertEqual(1)
      expect(detail.steps[1].toolsUsed[0].status).assertEqual('failed')
      expect(detail.steps[1].toolsUsed[0].ms).assertEqual(200)
    })

    it('places a tool outside every window on the nearest step', 0, () => {
      const data = parseLedgerAll([
        record(1, 1, 1000, 10, 10, 10, 0, 1000, 100000),
        stepLine(1, 1, 1000, 400, 0, 0),
        record(1, 2, 2000, 10, 10, 10, 0, 1000, 100000),
        stepLine(1, 2, 2000, 400, 0, 0)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [
        mark('late', 2600, 2700, 'completed')
      ], 1)
      expect(detail.hasTools).assertTrue()
      expect(detail.steps[1].toolsUsed.length).assertEqual(1)
      expect(detail.steps[0].toolsUsed.length).assertEqual(0)
    })

    it('reports a first step that re-sent its prompt', 0, () => {
      const data = parseLedgerAll([
        record(1, 1, 1000, 5836, 20, 4608, 0, 10444, 1048576),
        stepLine(1, 1, 1000, 400, 0, 0)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [], 1)
      expect(detail.firstInput).assertEqual(5836)
      expect(detail.firstHit < 0.6).assertTrue()
    })

    it('keeps an untimed turn from swallowing earlier turns\' tools', 0, () => {
      // An old ledger: settlements, no step timing lines.
      const data = parseLedgerAll([
        record(1, 1, 1000, 10, 10, 10, 0, 1000, 100000),
        record(2, 1, 5000, 10, 10, 10, 0, 2000, 100000)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [
        mark('old-turn-tool', 800, 900, 'completed'),
        mark('this-turn-tool', 4000, 4200, 'completed')
      ], 2)
      expect(detail.steps.length).assertEqual(1)
      expect(detail.hasTiming).assertFalse()
      expect(detail.hasTools).assertFalse()
      expect(detail.steps[0].input).assertEqual(10)
      // No timing → no duration (an epoch difference is not a duration).
      expect(detail.durationMs).assertEqual(0)
    })

    it('counts a running tool without inventing a duration', 0, () => {
      const data = parseLedgerAll([
        record(1, 1, 1000, 10, 10, 10, 0, 1000, 100000),
        stepLine(1, 1, 1000, 400, 0, 0)
      ].join('\n'))
      const detail = turnDetail(data.records, data.steps, data.events, [
        mark('sleep', 800, 0, 'in_progress')
      ], 1)
      expect(detail.steps[0].toolsUsed[0].ms).assertEqual(0)
      expect(detail.toolCalls).assertEqual(1)
    })
  })
}
