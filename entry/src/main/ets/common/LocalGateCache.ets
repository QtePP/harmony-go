import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { normalizeLocalGateText } from './LocalGate'

/**
 * On-device counts for the local gate.
 *
 * The cache is a feedback loop, not an auto-promoter: it records which exact
 * inputs were handled locally and which ones fell through, so a frequently
 * repeated miss can be reviewed and turned into a rule in `LocalGate.ets`.
 * Automatically caching a model answer and serving it later would be a
 * different (and riskier) feature: the same wording can refer to changed files
 * or a different context.
 *
 * Stored at `<filesDir>/local-gate-cache.json`; capped at 200 entries, with the
 * input text truncated for display. Nothing leaves the device.
 */

const MAX_ENTRIES = 200
const MAX_KEY_CHARS = 200
const MAX_DISPLAY_CHARS = 60
const CACHE_FILE = 'local-gate-cache.json'

class GateEntry {
  key: string = ''
  count: number = 0
  lastAt: number = 0
  intent: string = ''
  hit: boolean = false
}

class GateCache {
  version: number = 1
  hits: number = 0
  misses: number = 0
  entries: GateEntry[] = []
}

export class LocalGateCache {
  private static data: GateCache = new GateCache()

  static async load(context: common.UIAbilityContext): Promise<void> {
    LocalGateCache.data = new GateCache()
    const path = `${context.filesDir}/${CACHE_FILE}`
    try {
      if (!fs.accessSync(path)) {
        return
      }
      const parsed = JSON.parse(fs.readTextSync(path)) as GateCache
      if (parsed === null || typeof parsed !== 'object') {
        return
      }
      LocalGateCache.data.version = typeof parsed.version === 'number' ? parsed.version : 1
      LocalGateCache.data.hits = typeof parsed.hits === 'number' ? parsed.hits : 0
      LocalGateCache.data.misses = typeof parsed.misses === 'number' ? parsed.misses : 0
      if (Array.isArray(parsed.entries)) {
        for (const entry of parsed.entries) {
          if (entry === null || typeof entry !== 'object' || typeof entry.key !== 'string') {
            continue
          }
          const row = new GateEntry()
          row.key = entry.key
          row.count = typeof entry.count === 'number' ? entry.count : 0
          row.lastAt = typeof entry.lastAt === 'number' ? entry.lastAt : 0
          row.intent = typeof entry.intent === 'string' ? entry.intent : ''
          row.hit = entry.hit === true
          LocalGateCache.data.entries.push(row)
        }
      }
    } catch (error) {
      LocalGateCache.data = new GateCache()
    }
  }

  /** Record a handled input (intent non-empty) or a fall-through. */
  static record(context: common.UIAbilityContext, text: string, hit: boolean, intent: string = ''): void {
    const key = normalizeLocalGateText(text)
    if (key.length === 0 || key.length > MAX_KEY_CHARS) {
      return
    }
    if (hit) {
      LocalGateCache.data.hits++
    } else {
      LocalGateCache.data.misses++
    }
    let row: GateEntry | null = null
    for (const entry of LocalGateCache.data.entries) {
      if (entry.key === key && entry.hit === hit) {
        row = entry
        break
      }
    }
    if (row === null) {
      row = new GateEntry()
      row.key = key
      row.hit = hit
      LocalGateCache.data.entries.push(row)
    }
    row.count++
    row.lastAt = Date.now()
    row.intent = intent
    if (LocalGateCache.data.entries.length > MAX_ENTRIES) {
      let oldest = 0
      for (let index = 1; index < LocalGateCache.data.entries.length; index++) {
        const candidate = LocalGateCache.data.entries[index]
        const current = LocalGateCache.data.entries[oldest]
        if (candidate.count < current.count ||
          (candidate.count === current.count && candidate.lastAt < current.lastAt)) {
          oldest = index
        }
      }
      LocalGateCache.data.entries.splice(oldest, 1)
    }
    LocalGateCache.persist(context)
  }

  /** Top repeated messages that still go to the agent. */
  static candidates(limit: number = 5): GateEntry[] {
    const misses = LocalGateCache.data.entries.filter((entry: GateEntry) => !entry.hit)
    misses.sort((a: GateEntry, b: GateEntry) => b.count - a.count || b.lastAt - a.lastAt)
    return misses.slice(0, limit)
  }

  static summary(): string {
    const lines: string[] = []
    lines.push(`hits ${LocalGateCache.data.hits} / misses ${LocalGateCache.data.misses}`)
    const top = LocalGateCache.candidates(5)
    if (top.length === 0) {
      lines.push('no repeated fall-through yet')
      return lines.join('\n')
    }
    for (const entry of top) {
      const text = entry.key.length > MAX_DISPLAY_CHARS ? `${entry.key.substring(0, MAX_DISPLAY_CHARS)}…` : entry.key
      lines.push(`${entry.count}× ${text}`)
    }
    return lines.join('\n')
  }

  static async reset(context: common.UIAbilityContext): Promise<void> {
    LocalGateCache.data = new GateCache()
    try {
      const path = `${context.filesDir}/${CACHE_FILE}`
      if (fs.accessSync(path)) {
        fs.unlinkSync(path)
      }
    } catch (error) {
      /* best effort */
    }
  }

  private static persist(context: common.UIAbilityContext): void {
    const path = `${context.filesDir}/${CACHE_FILE}`
    const temp = `${path}.tmp-${Date.now()}`
    try {
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, JSON.stringify(LocalGateCache.data))
      fs.closeSync(file.fd)
      fs.renameSync(temp, path)
    } catch (error) {
      try {
        if (fs.accessSync(temp)) {
          fs.unlinkSync(temp)
        }
      } catch (_) {
        /* best effort */
      }
    }
  }
}
