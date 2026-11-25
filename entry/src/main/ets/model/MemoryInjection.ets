import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'

/** One pinned fact as the ontology plugin wrote it into the injection ledger. */
export interface InjectedFact {
  predicate: string
  object: string
  qualifier: string
  source: string
  observedAt: string
}

/** One actual injection — not one turn: the plugin writes only when the pinned set changes. */
export interface MemoryInjection {
  at: number
  sessionId: string
  turn: number
  count: number
  removed: boolean
  facts: InjectedFact[]
}

/** Wire shape of one JSONL line; unknown/malformed fields are ignored. */
interface RawFact {
  p?: string
  o?: string
  q?: string
  src?: string
  at?: string
}

interface RawInjection {
  v?: number
  t?: number
  s?: string
  turn?: number
  n?: number
  removed?: number
  f?: RawFact[]
}

const MAX_RECORDS = 200

/**
 * Read the injection ledger the ontology plugin appends to.
 *
 * ACP does not surface the durable user message that carries pinned facts, so
 * this file is the only way the chat can say what entered the prompt. It is
 * read on each assistant settlement; the file is small and bounded.
 */
export class MemoryLedger {
  static read(context: common.UIAbilityContext): MemoryInjection[] {
    const path = `${context.filesDir}/dsh-home/ontology/injections.jsonl`
    let text = ''
    try {
      if (!fs.accessSync(path)) {
        return []
      }
      text = fs.readTextSync(path)
    } catch (error) {
      return []
    }
    const lines = text.split('\n')
    const start = Math.max(0, lines.length - MAX_RECORDS)
    const out: MemoryInjection[] = []
    for (let index = start; index < lines.length; index++) {
      const line = lines[index].trim()
      if (line.length === 0) {
        continue
      }
      let raw: RawInjection
      try {
        raw = JSON.parse(line) as RawInjection
      } catch (error) {
        continue
      }
      if (raw.v !== 1 || typeof raw.s !== 'string' || typeof raw.t !== 'number') {
        continue
      }
      const facts: InjectedFact[] = []
      const rows: RawFact[] = raw.f === undefined ? [] : raw.f
      for (const row of rows) {
        facts.push({
          predicate: typeof row.p === 'string' ? row.p : '',
          object: typeof row.o === 'string' ? row.o : '',
          qualifier: typeof row.q === 'string' ? row.q : '',
          source: typeof row.src === 'string' ? row.src : '',
          observedAt: typeof row.at === 'string' ? row.at : ''
        })
      }
      out.push({
        at: raw.t,
        sessionId: raw.s,
        turn: typeof raw.turn === 'number' ? raw.turn : 0,
        count: typeof raw.n === 'number' ? raw.n : facts.length,
        removed: raw.removed === 1,
        facts: facts
      })
    }
    out.sort((a: MemoryInjection, b: MemoryInjection) => a.at - b.at)
    return out
  }

  /**
   * Newest injection for one session inside the turn window, or null.
   *
   * The window is `[turnStartedAt, assistantMessageAt]`, which is exactly the
   * interval in which `agent/pre-step` can have injected something for this
   * turn. Older records are deliberately excluded: they belong to a turn that
   * already has its own chip.
   */
  static latestBetween(records: MemoryInjection[], sessionId: string, from: number, to: number): MemoryInjection | null {
    let chosen: MemoryInjection | null = null
    for (const record of records) {
      if (record.sessionId !== sessionId) {
        continue
      }
      if (record.at < from || record.at > to) {
        continue
      }
      if (chosen === null || record.at >= chosen.at) {
        chosen = record
      }
    }
    return chosen
  }
}
