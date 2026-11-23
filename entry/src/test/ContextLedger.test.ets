import { describe, it, expect } from '@ohos/hypium'
import {
  cacheHitOf,
  emptySummary,
  formatTokens,
  parseLedger,
  percentOf,
  recordsFor,
  shortModel,
  summarize
} from '../main/ets/model/ContextLedger'

/**
 * Ledger parsing and aggregation.
 *
 * The host plugin writes these lines; a read can catch a torn last line while
 * the next record is being appended, and old hosts may write a schema this
 * build does not know. Both must degrade to "fewer rows", never to a crash.
 */

function line(session: string, turn: number, step: number, seq: number, time: number,
  sys: number, tools: number, msg: number, input: number, output: number,
  cacheRead: number, cacheWrite: number): string {
  return JSON.stringify({
    v: 1,
    t: time,
    s: session,
    turn: turn,
    step: step,
    seq: seq,
    p: 'deepseek-official',
    m: 'deepseek-v4-flash',
    ctx: sys + tools + msg,
    win: 128000,
    sys: sys,
    tools: tools,
    msg: msg,
    inp: input,
    out: output,
    cr: cacheRead,
    cw: cacheWrite,
    rs: 10
  })
}

export default function contextLedgerTest() {
  describe('ContextLedger / parse', () => {
    it('reads valid lines and skips blank, torn, and unknown-schema lines', 0, () => {
      const text = [
        line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 900, 100, 4000, 0),
        '',
        '{"v":2,"s":"s-1"}',
        '{"v":1,"s":"s-1","turn":2',
        'not json at all',
        line('s-1', 1, 2, 2, 200, 1000, 5000, 2500, 950, 120, 4100, 50)
      ].join('\n')
      const records = parseLedger(text)
      expect(records.length).assertEqual(2)
      expect(records[0].turn).assertEqual(1)
      expect(records[1].step).assertEqual(2)
      expect(records[1].cw).assertEqual(50)
    })

    it('returns nothing for an empty file', 0, () => {
      expect(parseLedger('').length).assertEqual(0)
      expect(parseLedger('\n\n').length).assertEqual(0)
      // `null` and an array are valid JSON but not records; neither may throw.
      expect(parseLedger('null\n[]').length).assertEqual(0)
    })

    it('clamps negative numbers to zero instead of trusting the writer', 0, () => {
      const evil = '{"v":1,"s":"s-1","turn":-3,"ctx":-1,"inp":-9}'
      const records = parseLedger(evil)
      expect(records.length).assertEqual(1)
      expect(records[0].turn).assertEqual(0)
      expect(records[0].ctx).assertEqual(0)
      expect(records[0].inp).assertEqual(0)
    })
  })

  describe('ContextLedger / filter', () => {
    it('keeps one session and orders by commit time', 0, () => {
      const text = [
        line('s-1', 1, 2, 2, 200, 1000, 5000, 2500, 950, 120, 4100, 50),
        line('s-2', 9, 1, 9, 150, 1, 2, 3, 4, 5, 6, 7),
        line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 900, 100, 4000, 0)
      ].join('\n')
      const records = recordsFor(parseLedger(text), 's-1')
      expect(records.length).assertEqual(2)
      expect(records[0].seq).assertEqual(1)
      expect(records[1].seq).assertEqual(2)
    })
  })

  describe('ContextLedger / summarize', () => {
    it('sums a turn across steps and keeps the last pressure and composition', 0, () => {
      const records = parseLedger([
        line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 900, 100, 4000, 0),
        line('s-1', 1, 2, 2, 200, 1000, 5000, 2500, 950, 120, 4100, 50),
        line('s-1', 2, 1, 3, 300, 1200, 5000, 3000, 1000, 200, 4200, 0)
      ].join('\n'))
      const summary = summarize(recordsFor(records, 's-1'))
      expect(summary.records).assertEqual(3)
      expect(summary.turns.length).assertEqual(2)
      expect(summary.turns[0].steps).assertEqual(2)
      expect(summary.turns[0].input).assertEqual(1850)
      expect(summary.turns[0].output).assertEqual(220)
      expect(summary.turns[1].context).assertEqual(9200)
      expect(summary.system).assertEqual(1200)
      expect(summary.tools).assertEqual(5000)
      expect(summary.messages).assertEqual(3000)
      expect(summary.context).assertEqual(9200)
      expect(summary.window).assertEqual(128000)
      expect(summary.totalCacheRead).assertEqual(12300)
      expect(summary.cacheHit > 0.8).assertTrue()
    })

    it('keeps only the newest twelve turns', 0, () => {
      const lines: string[] = []
      for (let turn = 1; turn <= 20; turn++) {
        lines.push(line('s-1', turn, 1, turn, turn * 100, 1, 2, 3, 4, 5, 6, 7))
      }
      const summary = summarize(parseLedger(lines.join('\n')))
      expect(summary.turns.length).assertEqual(12)
      expect(summary.turns[0].turn).assertEqual(9)
      expect(summary.turns[11].turn).assertEqual(20)
    })

    it('returns the empty summary for no records', 0, () => {
      const summary = summarize([])
      expect(summary.records).assertEqual(0)
      expect(summary.latest === null).assertTrue()
      expect(summary.cacheHit).assertEqual(0)
      expect(emptySummary().turns.length).assertEqual(0)
    })
  })

  describe('ContextLedger / format', () => {
    it('scales token counts', 0, () => {
      expect(formatTokens(0)).assertEqual('0')
      expect(formatTokens(999)).assertEqual('999')
      expect(formatTokens(1234)).assertEqual('1.2k')
      expect(formatTokens(1234567)).assertEqual('1.2M')
    })

    it('computes cache hit only when something was billed as input', 0, () => {
      expect(cacheHitOf(0, 0, 0)).assertEqual(0)
      expect(cacheHitOf(100, 900, 0)).assertEqual(0.9)
    })

    it('clamps percentages and shortens a model id', 0, () => {
      expect(percentOf(1, 0)).assertEqual(0)
      expect(percentOf(1, 3)).assertEqual(33)
      expect(percentOf(5, 3)).assertEqual(100)
      expect(shortModel('deepseek-v4-flash')).assertEqual('v4-flash')
      expect(shortModel('local')).assertEqual('local')
      expect(shortModel('')).assertEqual('')
    })
  })
}
