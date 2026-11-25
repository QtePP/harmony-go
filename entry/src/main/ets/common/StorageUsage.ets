import { common } from '@kit.AbilityKit'
import { fileIo as fs, storageStatistics } from '@kit.CoreFileKit'

/**
 * One measured slice of the app's on-device footprint.
 *
 * `estimated` is honest about where the number comes from: the runtime row is
 * derived by subtracting the small directories from the system `dataSize`,
 * because walking 95k files in `payload/` on the UI thread would freeze the
 * panel for seconds.
 */
export interface StorageRow {
  id: string
  label: string
  note: string
  bytes: number
  estimated: boolean
}

export interface StorageReport {
  /** Installation files (HAP + resources), from storageStatistics. */
  appSize: number
  /** Application data (filesDir), from storageStatistics. */
  dataSize: number
  /** Cache files, from storageStatistics. */
  cacheSize: number
  /** appSize + dataSize (dataSize already includes cache on this platform). */
  total: number
  rows: StorageRow[]
  /** Human note about the measurement boundary. */
  boundary: string
}

/** Stop a recursive scan before a pathological tree can stall the panel. */
const MAX_SCAN_ENTRIES = 20000

class ScanBudget {
  entries: number = 0
}

async function dirSize(path: string, budget: ScanBudget): Promise<number> {
  if (budget.entries > MAX_SCAN_ENTRIES) {
    return 0
  }
  let names: string[] = []
  try {
    names = await fs.listFile(path)
  } catch (error) {
    return 0
  }
  let total = 0
  for (const name of names) {
    if (budget.entries > MAX_SCAN_ENTRIES) {
      break
    }
    budget.entries += 1
    const child = `${path}/${name}`
    try {
      const stat = await fs.stat(child)
      if (stat.isDirectory()) {
        total += await dirSize(child, budget)
      } else {
        total += stat.size
      }
    } catch (error) {
      // A file can disappear between list and stat (rotation, cache cleanup);
      // the next refresh picks up the truth.
    }
  }
  return total
}

async function fileSize(path: string): Promise<number> {
  try {
    const stat = await fs.stat(path)
    return stat.isFile() ? stat.size : 0
  } catch (error) {
    return 0
  }
}

function label(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`
}

/**
 * Measure what the app occupies, without walking the runtime tree.
 *
 * `storageStatistics.getCurrentBundleStats()` is the system's own accounting
 * (installed app / data / cache). The detail rows are local scans of the small
 * directories plus a derived runtime size, because `payload/` is ~95k files and
 * a full walk is both slow and pointless: the runtime is "whatever data is
 * left after the directories we can name".
 */
export class StorageUsage {
  static format(bytes: number): string {
    return label(bytes)
  }

  static async collect(context: common.UIAbilityContext): Promise<StorageReport> {
    let appSize = 0
    let dataSize = 0
    let cacheSize = 0
    let boundary = '系统口径来自 storageStatistics；本机实测应用数据已含缓存，总占用 = 安装包 + 应用数据。分项为本地扫描/估算，可能相差几 MB。'
    try {
      const stats = await storageStatistics.getCurrentBundleStats()
      appSize = stats.appSize
      dataSize = stats.dataSize
      cacheSize = stats.cacheSize
    } catch (error) {
      boundary = '系统存储统计不可用；以下分项来自本地扫描，总量可能偏小。'
    }

    const files = context.filesDir
    const budget = new ScanBudget()
    const dshHome = await dirSize(`${files}/dsh-home`, budget)
    const workspace = await dirSize(`${files}/workspace`, budget)
    const workspaces = await dirSize(`${files}/workspaces`, budget)
    const tmp = await dirSize(`${files}/tmp`, budget)
    const cache = await dirSize(context.cacheDir, budget)
    const archive = await fileSize(`${files}/payload.zip`)

    // On this device `dataSize` already includes `cacheSize` (verified against
    // `du`: 1.72 GiB data ≈ 1.53 GiB files + 0.19 GiB cache), so subtract both
    // the named directories and the system cache before calling the remainder
    // "runtime". Clamp because accounting can still include a few extra files.
    const payload = Math.max(0, dataSize - dshHome - workspace - workspaces - tmp - archive - cacheSize)

    const rows: StorageRow[] = [
      {
        id: 'payload',
        label: '运行时载荷（解包后）',
        note: 'Node v24.2 + dsh；首启解包后常驻',
        bytes: payload,
        estimated: true
      }
    ]
    if (archive > 0) {
      rows.push({
        id: 'archive',
        label: '载荷压缩副本',
        note: '旧版本遗留；下次启动会自动删除',
        bytes: archive,
        estimated: false
      })
    }
    rows.push(
      {
        id: 'dsh-home',
        label: '会话与运行时数据',
        note: 'sessions / ontology / credentials / logs',
        bytes: dshHome,
        estimated: false
      },
      {
        id: 'workspace',
        label: '默认项目工作区',
        note: 'workspace/ 下的文件与仓库',
        bytes: workspace,
        estimated: false
      }
    )
    if (workspaces > 0) {
      rows.push({
        id: 'workspaces',
        label: '其它项目工作区',
        note: 'workspaces/<projectId>/',
        bytes: workspaces,
        estimated: false
      })
    }
    if (tmp > 0) {
      rows.push({
        id: 'tmp',
        label: '运行时临时文件',
        note: 'tmp/；可安全清理',
        bytes: tmp,
        estimated: false
      })
    }
    rows.push({
      id: 'cache',
      label: '缓存与导出（可清理）',
      note: 'cacheDir：长图 / PDF / 分享临时文件；系统缓存还含 WebView/图片缓存',
      bytes: cache,
      estimated: false
    })

    return {
      appSize: appSize,
      dataSize: dataSize,
      cacheSize: cacheSize,
      // dataSize already includes cacheSize on this platform; adding cache
      // again would show a total that is ~200 MB too large.
      total: appSize + dataSize,
      rows: rows,
      boundary: boundary
    }
  }

  /** Remove everything under cacheDir except an in-flight sync; returns freed bytes. */
  static async clearCache(context: common.UIAbilityContext): Promise<number> {
    const protectedSize = await dirSize(`${context.cacheDir}/sync-incoming`, new ScanBudget())
    const before = await dirSize(context.cacheDir, new ScanBudget()) - protectedSize
    let names: string[] = []
    try {
      names = await fs.listFile(context.cacheDir)
    } catch (error) {
      return 0
    }
    for (const name of names) {
      // Never delete a receive in progress: project sync stages its manifest
      // and chunks here, and the sender may still be writing.
      if (name === 'sync-incoming') {
        continue
      }
      const path = `${context.cacheDir}/${name}`
      try {
        const stat = await fs.stat(path)
        if (stat.isDirectory()) {
          await fs.rmdir(path)
        } else {
          await fs.unlink(path)
        }
      } catch (error) {
        // A share sheet may still hold a file; leave it for the next cleanup.
      }
    }
    const after = await dirSize(context.cacheDir, new ScanBudget()) - protectedSize
    return Math.max(0, before - after)
  }
}
