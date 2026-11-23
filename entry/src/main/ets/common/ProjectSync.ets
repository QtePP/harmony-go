import { common } from '@kit.AbilityKit'
import { socket } from '@kit.NetworkKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'

/**
 * Project sync: move a project's files from one device to another.
 *
 * This is not the interop message channel. Messages are one line of JSON, and
 * the only thing they carry is text; a project is a directory tree with binary
 * files that can be tens of megabytes, and a half-written tree on the receiver
 * is worse than no transfer at all. So: a length-prefixed binary framing, a
 * manifest agreed up front, per-file staging, and an atomic move only once the
 * whole tree has arrived and every size checks out.
 *
 * Wire format, both directions, big-endian:
 *
 *   [u32 headerLen][header JSON utf-8][u32 dataLen][dataLen raw bytes]
 *
 * The header names the frame type; `data` carries file bytes for chunks and is
 * empty for control frames. Both ends are this app, so the protocol is free to
 * be boring rather than self-describing.
 *
 * Security posture: nothing listens until the user opens receiving mode, and
 * the receiver displays a one-time code that the sender must repeat in its
 * hello. A LAN port that accepts files from anyone who finds it would be a
 * remote file write primitive, which is the one thing this app must not grow.
 */

/** One file the sender will transmit, relative to the project root. */
export interface SyncEntry {
  path: string
  size: number
}

/** Where a transfer is, for the progress line in the UI. */
export interface SyncProgress {
  phase: string
  filesDone: number
  filesTotal: number
  bytesDone: number
  bytesTotal: number
  detail: string
}

/** What a finished transfer did. */
export interface SyncReport {
  files: number
  bytes: number
  /** Files the receiver refused to overwrite because they already existed. */
  skipped: string[]
}

/** Directory names never worth sending: they are regenerable and huge. */
const SKIP_DIRS: string[] = ['.git', 'node_modules', '.hvigor', '.build']

/** Single-file ceiling; larger files are reported rather than silently cut. */
const MAX_FILE_BYTES: number = 64 * 1024 * 1024

/** Chunk payload size. Fits the 65535-byte NearLink packet cap with room. */
export const SYNC_CHUNK_BYTES: number = 32 * 1024

/** Default port; the receiver may bind another one if this is taken. */
export const SYNC_PORT: number = 4519

/** Frame types on the wire. */
const T_HELLO: string = 'hello'
const T_ACCEPT: string = 'accept'
const T_DENY: string = 'deny'
const T_FILE: string = 'file'
const T_CHUNK: string = 'chunk'
const T_FILE_END: string = 'fileEnd'
const T_SESSIONS: string = 'sessions'
const T_DONE: string = 'done'
const T_ERROR: string = 'error'

interface SyncFrame {
  t: string
  code?: string
  name?: string
  version?: number
  path?: string
  size?: number
  reason?: string
  files?: number
  bytes?: number
  entries?: SyncEntry[]
}

/** One decoded frame: parsed header plus its payload, if any. */
interface SyncFrameBox {
  header: SyncFrame
  data: ArrayBuffer | null
}

/** Encode a u32 big-endian into four bytes. */
function u32(value: number): Uint8Array {
  const out = new Uint8Array(4)
  out[0] = (value >>> 24) & 0xff
  out[1] = (value >>> 16) & 0xff
  out[2] = (value >>> 8) & 0xff
  out[3] = value & 0xff
  return out
}

/** Read a u32 big-endian from four bytes. */
function readU32(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0
}

/** One frame ready to put on the wire: header JSON plus optional payload. */
function frame(header: SyncFrame, data?: ArrayBuffer): ArrayBuffer {
  const json = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(header))
  const dataLen = data === undefined ? 0 : data.byteLength
  const out = new Uint8Array(4 + json.length + 4 + dataLen)
  out.set(u32(json.length), 0)
  out.set(json, 4)
  out.set(u32(dataLen), 4 + json.length)
  if (data !== undefined && dataLen > 0) {
    out.set(new Uint8Array(data), 8 + json.length)
  }
  return out.buffer as ArrayBuffer
}

/**
 * Incremental frame decoder.
 *
 * TCP delivers bytes, not frames: a chunk can arrive split across two reads or
 * several frames can arrive together. Everything accumulates here until a whole
 * frame is present.
 */
class FrameReader {
  private buffer: Uint8Array = new Uint8Array(0)
  /** Decoded headers, in arrival order; `data` holds the payload or null. */
  private headers: SyncFrame[] = []
  private payloads: (ArrayBuffer | null)[] = []

  push(bytes: ArrayBuffer): void {
    const incoming = new Uint8Array(bytes)
    const merged = new Uint8Array(this.buffer.length + incoming.length)
    merged.set(this.buffer, 0)
    merged.set(incoming, this.buffer.length)
    this.buffer = merged
    this.drain()
  }

  /** Whether a whole frame is already decoded, without consuming it. */
  hasFrame(): boolean {
    return this.headers.length > 0
  }

  /** Next frame, or null when the buffer does not yet hold a whole one. */
  next(): SyncFrameBox | null {
    if (this.headers.length === 0) {
      return null
    }
    const header = this.headers.shift() as SyncFrame
    const data = this.payloads.shift() as ArrayBuffer | null
    return { header: header, data: data }
  }

  private drain(): void {
    while (this.buffer.length >= 4) {
      const headerLen = readU32(this.buffer, 0)
      if (headerLen > 1024 * 1024) {
        // A corrupt length means the stream is unusable; drop what we have.
        this.buffer = new Uint8Array(0)
        return
      }
      if (this.buffer.length < 4 + headerLen + 4) {
        return
      }
      const headerText = util.TextDecoder.create('utf-8')
        .decodeToString(this.buffer.subarray(4, 4 + headerLen))
      const dataLen = readU32(this.buffer, 4 + headerLen)
      const total = 4 + headerLen + 4 + dataLen
      if (this.buffer.length < total) {
        return
      }
      let header: SyncFrame
      try {
        header = JSON.parse(headerText) as SyncFrame
      } catch (error) {
        this.buffer = new Uint8Array(0)
        return
      }
      const payload = dataLen === 0
        ? null
        : this.buffer.slice(8 + headerLen, total).buffer as ArrayBuffer
      this.headers.push(header)
      this.payloads.push(payload)
      this.buffer = this.buffer.slice(total)
    }
  }
}

/** Join `root` and a manifest-relative path without trusting `..`. */
function resolveInside(root: string, relative: string): string {
  const parts = relative.split('/')
  for (const part of parts) {
    if (part === '..' || part.length === 0) {
      throw new Error(`同步清单里有非法路径：${relative}`)
    }
  }
  return `${root}/${relative}`
}

/** Recursively list files under `dir`, relative to `root`. */
function walk(root: string, dir: string, relative: string, out: SyncEntry[], skipped: string[]): void {
  let names: string[] = []
  try {
    names = fs.listFileSync(dir)
  } catch (error) {
    skipped.push(relative.length === 0 ? '/' : relative)
    return
  }
  for (const name of names) {
    const full = `${dir}/${name}`
    const rel = relative.length === 0 ? name : `${relative}/${name}`
    let stat: fs.Stat
    try {
      stat = fs.statSync(full)
    } catch (error) {
      skipped.push(rel)
      continue
    }
    if (stat.isDirectory()) {
      if (SKIP_DIRS.includes(name)) {
        continue
      }
      walk(root, full, rel, out, skipped)
      continue
    }
    if (!stat.isFile()) {
      continue
    }
    if (stat.size > MAX_FILE_BYTES) {
      skipped.push(`${rel}（超过 ${Math.round(MAX_FILE_BYTES / 1024 / 1024)}MB）`)
      continue
    }
    out.push({ path: rel, size: stat.size })
  }
}

/**
 * Build the manifest for one project.
 *
 * `include` holds top-level names to send; an empty list means everything under
 * the workspace. The cap is per file, so a 300MB folder of small files is still
 * allowed — what we refuse is a single file so large that a phone cannot hold
 * both halves of it comfortably in memory.
 */
export function collectEntries(root: string, include: string[], skipped: string[]): SyncEntry[] {
  const out: SyncEntry[] = []
  if (include.length === 0) {
    walk(root, root, '', out, skipped)
    return out
  }
  for (const name of include) {
    const full = `${root}/${name}`
    let stat: fs.Stat
    try {
      stat = fs.statSync(full)
    } catch (error) {
      skipped.push(name)
      continue
    }
    if (stat.isDirectory()) {
      walk(root, full, name, out, skipped)
    } else if (stat.isFile() && stat.size <= MAX_FILE_BYTES) {
      out.push({ path: name, size: stat.size })
    } else {
      skipped.push(name)
    }
  }
  return out
}

/** Total bytes in a manifest. */
export function totalBytes(entries: SyncEntry[]): number {
  let sum = 0
  for (const entry of entries) {
    sum += entry.size
  }
  return sum
}

/** A six-digit code the receiver shows and the sender must repeat. */
export function makePairCode(): string {
  const value = Math.floor(Math.random() * 1000000)
  const text = `${value}`
  return text.length === 6 ? text : '0'.repeat(6 - text.length) + text
}

/**
 * Sender: connect, hand over the manifest, stream every file.
 *
 * Flow control is one chunk in flight: `send` resolves when the socket accepted
 * the bytes, which is the only backpressure signal this API exposes. It keeps
 * memory flat, and on a slow link it is what prevents the writer from queueing
 * a whole file in the OS.
 */
export async function sendProject(
  root: string,
  entries: SyncEntry[],
  host: string,
  port: number,
  code: string,
  name: string,
  sessionsJson: string,
  onProgress: (progress: SyncProgress) => void,
  cancelled: () => boolean
): Promise<SyncReport> {
  const total = totalBytes(entries)
  const tcp = socket.constructTCPSocketInstance()
  await tcp.bind({ address: '0.0.0.0', port: 0, family: 1 })
  await tcp.connect({ address: { address: host, port: port, family: 1 }, timeout: 8000 })

  const reader: FrameReader = new FrameReader()
  let accepted = false
  let denied = ''
  tcp.on('message', (info: socket.SocketMessageInfo) => {
    reader.push(info.message)
  })
  tcp.on('close', () => {
    accepted = false
  })

  const waitFor = async (wanted: string): Promise<SyncFrame> => {
    for (let i = 0; i < 200; i++) {
      const frameOrNull = reader.next()
      if (frameOrNull !== null) {
        if (frameOrNull.header.t === wanted) {
          return frameOrNull.header
        }
        if (frameOrNull.header.t === T_DENY) {
          denied = frameOrNull.header.reason === undefined ? '对方拒绝接收' : frameOrNull.header.reason
          throw new Error(denied)
        }
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 50))
    }
    throw new Error('对方没有回应（可能不在接收模式）')
  }

  try {
    await tcp.send({
      data: frame({
        t: T_HELLO, version: 1, code: code, name: name,
        files: entries.length, bytes: total, entries: entries
      })
    })
    await waitFor(T_ACCEPT)
    accepted = true
    // Conversations ride on their own frame before the files: they are a few
    // hundred KB of JSON at most, and keeping them out of the manifest means
    // the receiver can import them with the same code path that reads its own
    // store, instead of unpacking a pseudo-file.
    if (sessionsJson.length > 0) {
      const encoded = util.TextEncoder.create('utf-8').encodeInto(sessionsJson)
      await tcp.send({ data: frame({ t: T_SESSIONS }, encoded.buffer as ArrayBuffer) })
    }

    let filesDone = 0
    let bytesDone = 0
    onProgress({
      phase: 'send', filesDone: 0, filesTotal: entries.length,
      bytesDone: 0, bytesTotal: total, detail: '开始发送'
    })

    for (const entry of entries) {
      if (cancelled()) {
        await tcp.send({ data: frame({ t: T_ERROR, reason: 'cancelled' }) })
        throw new Error('已取消')
      }
      const source = fs.openSync(resolveInside(root, entry.path), fs.OpenMode.READ_ONLY)
      try {
        await tcp.send({ data: frame({ t: T_FILE, path: entry.path, size: entry.size }) })
        let sent = 0
        while (sent < entry.size) {
          const want = Math.min(SYNC_CHUNK_BYTES, entry.size - sent)
          const buffer = new ArrayBuffer(want)
          const read = fs.readSync(source.fd, buffer, { offset: sent, length: want })
          if (read <= 0) {
            throw new Error(`读取文件提前结束：${entry.path}`)
          }
          const slice = read === want ? buffer : buffer.slice(0, read) as ArrayBuffer
          await tcp.send({ data: frame({ t: T_CHUNK }, slice) })
          sent += read
          bytesDone += read
          onProgress({
            phase: 'send', filesDone: filesDone, filesTotal: entries.length,
            bytesDone: bytesDone, bytesTotal: total, detail: entry.path
          })
          if (cancelled()) {
            await tcp.send({ data: frame({ t: T_ERROR, reason: 'cancelled' }) })
            throw new Error('已取消')
          }
        }
        await tcp.send({ data: frame({ t: T_FILE_END, path: entry.path, size: entry.size }) })
        filesDone++
      } finally {
        fs.closeSync(source)
      }
    }

    await tcp.send({
      data: frame({ t: T_DONE, files: filesDone, bytes: bytesDone })
    })
    onProgress({
      phase: 'done', filesDone: filesDone, filesTotal: entries.length,
      bytesDone: bytesDone, bytesTotal: total, detail: '发送完成'
    })
    return { files: filesDone, bytes: bytesDone, skipped: [] }
  } finally {
    try {
      tcp.off('message')
    } catch (error) {
      // Already gone.
    }
    try {
      await tcp.close()
    } catch (error) {
      // Closing a dead socket is not news.
    }
    if (!accepted && denied.length === 0) {
      // Caller gets the thrown error; nothing else to do here.
    }
  }
}

/** Where an incoming tree is written before it replaces anything. */
function stagingDir(context: common.UIAbilityContext): string {
  return `${context.cacheDir}/sync-incoming`
}

/** Remove a directory tree; best effort, used to clear old staging. */
export function removeTree(path: string): void {
  try {
    if (!fs.accessSync(path)) {
      return
    }
    for (const name of fs.listFileSync(path)) {
      const full = `${path}/${name}`
      const stat = fs.statSync(full)
      if (stat.isDirectory()) {
        removeTree(full)
      } else {
        fs.unlinkSync(full)
      }
    }
    fs.rmdirSync(path)
  } catch (error) {
    // Leftovers in cache are the OS's to reclaim.
  }
}

/**
 * Receiver: listen once, take one tree, move it in.
 *
 * The code is checked against the sender's hello before a single byte is
 * written, and the incoming tree is assembled under cacheDir so a cancelled or
 * broken transfer cannot leave half a project inside the workspace. Only after
 * the sender's `done` frame does anything move, file by file.
 */
export class SyncReceiver {
  private server: socket.TCPSocketServer | null = null
  private conn: socket.TCPSocketConnection | null = null
  private reader: FrameReader = new FrameReader()
  private code: string = ''
  private targetRoot: string = ''
  private staging: string = ''
  private report: SyncReport = { files: 0, bytes: 0, skipped: [] }
  private failure: string = ''
  private finished: boolean = false

  /** The code to show while waiting; set by `open`. */
  get pairCode(): string {
    return this.code
  }

  /**
   * Start listening. Resolves with the bound port.
   *
   * `onProgress` reports receiving progress; `onFinished` is called once when
   * the tree has been moved into the workspace (or with the error text).
   */
  async open(
    context: common.UIAbilityContext,
    targetRoot: string,
    onProgress: (progress: SyncProgress) => void,
    onSessions: (json: string) => void,
    onFinished: (report: SyncReport, error: string) => void
  ): Promise<number> {
    await this.close()
    this.targetRoot = targetRoot
    this.staging = stagingDir(context)
    removeTree(this.staging)
    fs.mkdirSync(this.staging)
    this.code = makePairCode()
    this.report = { files: 0, bytes: 0, skipped: [] }
    this.failure = ''
    this.finished = false

    const server = socket.constructTCPSocketServerInstance()
    let port = SYNC_PORT
    try {
      await server.listen({ address: '0.0.0.0', port: port, family: 1 })
    } catch (error) {
      // Port taken by an earlier instance: take any free one and tell the user.
      port = 0
      await server.listen({ address: '0.0.0.0', port: port, family: 1 })
    }
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.attach(conn, onProgress, onSessions, onFinished)
    })
    this.server = server
    return port
  }

  /** Stop listening and drop the connection; staging is cleared on next open. */
  async close(): Promise<void> {
    if (this.conn !== null) {
      try {
        await this.conn.close()
      } catch (error) {
        // Already closed.
      }
      this.conn = null
    }
    if (this.server !== null) {
      try {
        this.server.off('connect')
      } catch (error) {
        // No listener registered.
      }
      try {
        this.server.close()
      } catch (error) {
        // Already closed.
      }
      this.server = null
    }
  }

  private attach(
    conn: socket.TCPSocketConnection,
    onProgress: (progress: SyncProgress) => void,
    onSessions: (json: string) => void,
    onFinished: (report: SyncReport, error: string) => void
  ): void {
    this.conn = conn
    this.reader = new FrameReader()
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.reader.push(info.message)
    })
    conn.on('close', () => {
      if (!this.finished) {
        this.failure = 'peer closed'
      }
    })
    let handshook = false
    let entries: SyncEntry[] = []
    let total = 0
    let filesDone = 0
    let bytesDone = 0
    let sessionsJson = ''
    let currentPath = ''
    let currentSize = 0
    let currentWritten = 0
    let currentFile: fs.File | null = null
    let currentFull = ''

    const finish = (error: string): void => {
      if (this.finished) {
        return
      }
      this.finished = true
      if (currentFile !== null) {
        try {
          fs.closeSync(currentFile)
        } catch (closeError) {
          // Best effort.
        }
        currentFile = null
      }
      if (error.length > 0) {
        onFinished(this.report, error)
        void this.close()
        return
      }
      // Move the tree in: every file has been written and size-checked.
      const moved: string[] = []
      try {
        for (const entry of entries) {
          const source = resolveInside(this.staging, entry.path)
          const destination = resolveInside(this.targetRoot, entry.path)
          const parent = destination.substring(0, destination.lastIndexOf('/'))
          if (!fs.accessSync(parent)) {
            fs.mkdirSync(parent, true)
          }
          if (fs.accessSync(destination)) {
            // Overwriting silently could destroy work the user has not synced
            // themselves; report it instead and let them decide.
            this.report.skipped.push(entry.path)
            continue
          }
          fs.renameSync(source, destination)
          moved.push(entry.path)
        }
        this.report.files = moved.length
        this.report.bytes = bytesDone
        if (sessionsJson.length > 0) {
          onSessions(sessionsJson)
        }
        onFinished(this.report, '')
      } catch (moveError) {
        onFinished(this.report, `写入工作区失败：${(moveError as Error).message}`)
      } finally {
        removeTree(this.staging)
        void this.close()
      }
    }

    void (async (): Promise<void> => {
      try {
        for (;;) {
          let next = this.reader.next()
          while (next === null) {
            const closing = await this.waitForData()
            if (closing) {
              finish('对方中途断开')
              return
            }
            next = this.reader.next()
          }
          const header = next.header
          const data = next.data
          if (header.t === T_HELLO) {
            if (header.code !== this.code) {
              await conn.send({ data: frame({ t: T_DENY, reason: '配对码不对' }) })
              finish('配对码不对，已拒绝')
              return
            }
            entries = header.entries === undefined ? [] : header.entries
            total = 0
            for (const entry of entries) {
              total += entry.size
            }
            handshook = true
            await conn.send({ data: frame({ t: T_ACCEPT }) })
            onProgress({
              phase: 'receive', filesDone: 0, filesTotal: entries.length,
              bytesDone: 0, bytesTotal: total, detail: '开始接收'
            })
            continue
          }
          if (!handshook) {
            finish('对方没有先握手')
            return
          }
          if (header.t === T_SESSIONS) {
            if (data !== null) {
              sessionsJson = util.TextDecoder.create('utf-8')
                .decodeToString(new Uint8Array(data))
            }
            continue
          }
          if (header.t === T_FILE) {
            currentPath = header.path === undefined ? '' : header.path
            currentSize = header.size === undefined ? 0 : header.size
            currentWritten = 0
            currentFull = resolveInside(this.staging, currentPath)
            const parent = currentFull.substring(0, currentFull.lastIndexOf('/'))
            if (!fs.accessSync(parent)) {
              fs.mkdirSync(parent, true)
            }
            currentFile = fs.openSync(currentFull,
              fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
            continue
          }
          if (header.t === T_CHUNK) {
            if (currentFile === null || data === null) {
              finish('收到意外的数据块')
              return
            }
            fs.writeSync(currentFile.fd, data)
            currentWritten += data.byteLength
            bytesDone += data.byteLength
            onProgress({
              phase: 'receive', filesDone: filesDone, filesTotal: entries.length,
              bytesDone: bytesDone, bytesTotal: total, detail: currentPath
            })
            continue
          }
          if (header.t === T_FILE_END) {
            if (currentFile !== null) {
              fs.closeSync(currentFile)
              currentFile = null
            }
            if (currentWritten !== currentSize) {
              finish(`${currentPath} 大小不符（收到 ${currentWritten}，声明 ${currentSize}）`)
              return
            }
            filesDone++
            continue
          }
          if (header.t === T_ERROR) {
            finish(header.reason === undefined ? '对方中止了传输' : `对方中止：${header.reason}`)
            return
          }
          if (header.t === T_DONE) {
            finish('')
            return
          }
        }
      } catch (error) {
        finish(`接收失败：${(error as Error).message}`)
      }
    })()
  }

  /**
   * Wait until more bytes arrive on the connection.
   *
   * The socket reader pushes into `reader`; this polls the connection's own
   * buffer by attempting a read every 50 ms. Resolves true when the peer is gone.
   */
  private async waitForData(): Promise<boolean> {
    for (let i = 0; i < 600; i++) {
      if (this.failure.length > 0) {
        return true
      }
      if (this.reader.hasFrame()) {
        return false
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 50))
    }
    return true
  }
}
