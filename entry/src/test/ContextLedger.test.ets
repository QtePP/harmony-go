import { describe, it, expect } from '@ohos/hypium'
import {
  cacheHitOf,
  isRecompute,
  emptySummary,
  eventKindLabel,
  eventsFor,
  formatDuration,
  formatTokens,
  parseLedger,
  parseLedgerAll,
  percentOf,
  producerLabel,
  recordsFor,
  shortModel,
  stepsFor,
  summarize,
  trendOf
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
      // The turn's first step is the one a prefix rebuild shows up in.
      expect(summary.turns[0].firstInput).assertEqual(900)
      expect(summary.turns[0].firstHit > 0.8).assertTrue()
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

    it('separates steady-state cache from one-off prefix rebuilds', 0, () => {
      const records = parseLedger([
        line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 100, 100, 900, 0),
        line('s-1', 2, 1, 2, 200, 1000, 5000, 2000, 5000, 100, 4000, 0)
      ].join('\n'))
      const summary = summarize(recordsFor(records, 's-1'))
      expect(summary.recomputes).assertEqual(1)
      expect(summary.recomputeTokens).assertEqual(5000)
      expect(summary.steadySamples).assertEqual(1)
      // Steady hit ignores the rebuild step; the raw hit is dragged down by it.
      expect(Math.round(summary.steadyHit * 100)).assertEqual(90)
      expect(Math.round(summary.cacheHit * 100)).assertEqual(49)
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
      // A whole thousand drops the decimal: thresholds read `727k`, not `727.0k`.
      expect(formatTokens(727040)).assertEqual('727k')
      expect(formatTokens(1000000)).assertEqual('1M')
      expect(formatTokens(11600)).assertEqual('11.6k')
    })

    it('computes cache hit only when something was billed as input', 0, () => {
      expect(cacheHitOf(0, 0, 0)).assertEqual(0)
      expect(cacheHitOf(100, 900, 0)).assertEqual(0.9)
    })

    it('flags a step that re-sent its prompt', 0, () => {
      const big = parseLedger([line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 5836, 100, 4608, 0)].join('\n'))
      const small = parseLedger([line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 300, 100, 9000, 0)].join('\n'))
      expect(isRecompute(big[0])).assertTrue()
      expect(isRecompute(small[0])).assertFalse()
    })

    it('clamps percentages and shortens a model id', 0, () => {
      expect(percentOf(1, 0)).assertEqual(0)
      expect(percentOf(1, 3)).assertEqual(33)
      expect(percentOf(5, 3)).assertEqual(100)
      expect(shortModel('deepseek-v4-flash')).assertEqual('v4-flash')
      expect(shortModel('local')).assertEqual('local')
      expect(shortModel('')).assertEqual('')
    })

    it('formats durations and names the ledger vocabulary', 0, () => {
      expect(formatDuration(0)).assertEqual('0s')
      expect(formatDuration(42000)).assertEqual('42s')
      expect(formatDuration(93000)).assertEqual('1m33s')
      expect(formatDuration(120000)).assertEqual('2m')
      expect(formatDuration(3720000)).assertEqual('1h2m')
      expect(eventKindLabel('inject')).assertEqual('注入')
      expect(eventKindLabel('compact')).assertEqual('压缩')
      expect(eventKindLabel('weird')).assertEqual('weird')
      expect(producerLabel('time-context')).assertEqual('时间上下文')
      expect(producerLabel('ontology')).assertEqual('长期记忆')
      expect(producerLabel('other')).assertEqual('other')
    })
  })

  describe('ContextLedger / activity', () => {
    it('splits settlements, events, and steps by line kind', 0, () => {
      const text = [
        line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 900, 100, 4000, 0),
        '{"v":2,"k":"e","t":150,"s":"s-1","turn":1,"step":1,"kind":"inject","label":"time-context","d":120}',
        '{"v":2,"k":"s","t":160,"s":"s-1","turn":1,"step":1,"ms":3000,"tool":300,"n":1}',
        '{"v":2,"k":"e","t":170,"s":"s-2","turn":9,"step":1,"kind":"model","label":"deepseek-v4-pro","d":0}',
        '{"v":2,"k":"s","s":"s-1","turn":2'
      ].join('\n')
      const data = parseLedgerAll(text)
      expect(data.records.length).assertEqual(1)
      expect(data.events.length).assertEqual(2)
      expect(data.steps.length).assertEqual(1)
      expect(data.events[0].kind).assertEqual('inject')
      expect(data.events[0].d).assertEqual(120)
      expect(data.steps[0].ms).assertEqual(3000)
    })

    it('filters activity by session and keeps commit order', 0, () => {
      const data = parseLedgerAll([
        '{"v":2,"k":"e","t":300,"s":"s-1","turn":2,"kind":"model","label":"b","d":0}',
        '{"v":2,"k":"e","t":100,"s":"s-1","turn":1,"kind":"inject","label":"a","d":5}',
        '{"v":2,"k":"e","t":200,"s":"s-2","turn":1,"kind":"inject","label":"c","d":7}'
      ].join('\n'))
      const events = eventsFor(data.events, 's-1')
      expect(events.length).assertEqual(2)
      expect(events[0].label).assertEqual('a')
      expect(events[1].label).assertEqual('b')
      expect(eventsFor(data.events, '').length).assertEqual(0)
      expect(stepsFor(data.steps, 's-1').length).assertEqual(0)
    })

    it('aggregates the split, the peak, the trend, and the timing', 0, () => {
      const split = JSON.stringify({
        v: 1, t: 200, s: 's-1', turn: 1, step: 2, seq: 2, p: 'p', m: 'deepseek-v4-flash',
        ctx: 9000, win: 1000000, sys: 1000, tools: 5000, msg: 3000,
        u: 500, au: 700, tr: 1500, ij: 300, thr: 800000, rsv: 65536,
        inp: 900, out: 100, cr: 4000, cw: 0, rs: 10
      })
      const records = parseLedger([
        line('s-1', 1, 1, 1, 100, 1000, 5000, 2000, 900, 100, 4000, 0),
        split
      ].join('\n'))
      const steps = stepsFor(parseLedgerAll(
        '{"v":2,"k":"s","t":200,"s":"s-1","turn":1,"step":1,"ms":3000,"tool":300,"n":1}\n'
        + '{"v":2,"k":"s","t":400,"s":"s-1","turn":1,"step":2,"ms":2000,"tool":0,"n":0}'
      ).steps, 's-1')
      const summary = summarize(recordsFor(records, 's-1'), [], steps)
      expect(summary.splitUser).assertEqual(500)
      expect(summary.splitToolResult).assertEqual(1500)
      expect(summary.threshold).assertEqual(800000)
      expect(summary.reserved).assertEqual(65536)
      expect(summary.peak).assertEqual(9000)
      expect(summary.totalTurns).assertEqual(1)
      expect(summary.spanMs).assertEqual(100)
      expect(summary.steps).assertEqual(2)
      expect(summary.toolCalls).assertEqual(1)
      expect(summary.toolMs).assertEqual(300)
      expect(summary.stepMs).assertEqual(5000)
      expect(summary.trend.length).assertEqual(2)
      expect(summary.trend[1].delta).assertEqual(1000)
      expect(summary.trend[1].messages).assertEqual(3000)
    })

    it('keeps only the newest trend points', 0, () => {
      const lines: string[] = []
      for (let step = 1; step <= 30; step++) {
        lines.push(line('s-1', 1, step, step, step * 10, 1, 2, 3, 4, 5, 6, 7))
      }
      const points = trendOf(parseLedger(lines.join('\n')), 24)
      expect(points.length).assertEqual(24)
      expect(points[23].step).assertEqual(30)
    })
  })
}
