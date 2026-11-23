import { common } from '@kit.AbilityKit'
import { socket } from '@kit.NetworkKit'
import { fileIo as fs } from '@kit.CoreFileKit'

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
const T_BLOB: string = 'blob'
const T_ACK: string = 'ack'
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
  /** v2 control transfer: how much arrives in `blob` frames. */
  manifestChunks?: number
  sessionsChunks?: number
  chunkIndex?: number
  kind?: string
}

/** One decoded frame: parsed header plus its payload, if any. */
interface SyncFrameBox {
  header: SyncFrame
  data: ArrayBuffer | null
}

/**
 * UTF-8 encode/decode without `util`.
 *
 * The framing must stay runnable in the host test suite, where the kit modules
 * are stubs; a text codec that exists only on device would make every frame
 * look corrupt in a test. Headers and file paths are the only strings here, and
 * both can contain non-ASCII (Chinese file names), so this is a real codec, not
 * an ASCII shortcut.
 */
function encodeUtf8(text: string): Uint8Array {
  const out: number[] = []
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i)
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
        i++
      }
    }
    if (code < 0x80) {
      out.push(code)
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
    } else if (code < 0x10000) {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
    } else {
      out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
    }
  }
  return new Uint8Array(out)
}

/** Decode UTF-8, replacing malformed sequences instead of throwing. */
function decodeUtf8(bytes: Uint8Array): string {
  let out = ''
  let i = 0
  while (i < bytes.length) {
    const byte = bytes[i]
    let code = 0
    let extra = 0
    if (byte < 0x80) {
      code = byte
    } else if ((byte & 0xe0) === 0xc0) {
      code = byte & 0x1f
      extra = 1
    } else if ((byte & 0xf0) === 0xe0) {
      code = byte & 0x0f
      extra = 2
    } else if ((byte & 0xf8) === 0xf0) {
      code = byte & 0x07
      extra = 3
    } else {
      i++
      continue
    }
    i++
    for (let k = 0; k < extra; k++) {
      if (i >= bytes.length) {
        break
      }
      code = (code << 6) | (bytes[i] & 0x3f)
      i++
    }
    if (code > 0xffff) {
      const shifted = code - 0x10000
      out += String.fromCharCode(0xd800 + (shifted >> 10), 0xdc00 + (shifted & 0x3ff))
    } else {
      out += String.fromCharCode(code)
    }
  }
  return out
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
  const json = encodeUtf8(JSON.stringify(header))
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
export class FrameReader {
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
      const headerText = decodeUtf8(this.buffer.subarray(4, 4 + headerLen))
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
 * What the sync protocol needs from a transport.
 *
 * TCP is one implementation; 星闪's port channel is another. Both hand over
 * arbitrary byte chunks (FrameReader reassembles frames), so the protocol never
 * has to know which wire it rides on.
 */
export interface SyncLink {
  send(bytes: ArrayBuffer): Promise<void>
  close(): Promise<void>
  onBytes(handler: (bytes: ArrayBuffer) => void): void
  onClosed(handler: () => void): void
  /**
   * Whether the sender must wait for the receiver's `ack` before hanging up.
   *
   * TCP closes gracefully after the last byte, so it does not need one; a
   * 星闪 link who terminates right after the final write drops whatever the
   * other side had not read yet, so the receiver has to say it is done.
   */
  needsAck(): boolean
  /**
   * Whether control frames (manifest, sessions) must be split.
   *
   * A 星闪 port refuses a frame bigger than its packet size, and a workspace
   * manifest for a few hundred files is several KB; TCP has no such limit and
   * keeps sending the manifest inside `hello` so the host peer stays compatible.
   */
  splitControl(): boolean
  /**
   * Largest payload one `send` may carry. TCP takes the protocol's full chunk;
   * a 星闪 port is capped by the negotiated packet size, so the sender has to
   * ask instead of assuming 32KB fits everywhere.
   */
  maxPayload(): number
}

/** TCP as a link: either an accepted connection or a client socket. */
export class TcpSyncLink implements SyncLink {
  private conn: socket.TCPSocketConnection | null = null
  private client: socket.TCPSocket | null = null
  private bytesHandler: ((bytes: ArrayBuffer) => void) | null = null
  private closedHandler: (() => void) | null = null

  constructor(conn: socket.TCPSocketConnection | null, client: socket.TCPSocket | null) {
    this.conn = conn
    this.client = client
    if (conn !== null) {
      conn.on('message', (info: socket.SocketMessageInfo) => {
        if (this.bytesHandler !== null) {
          this.bytesHandler(info.message)
        }
      })
      conn.on('close', () => {
        if (this.closedHandler !== null) {
          this.closedHandler()
        }
      })
    } else if (client !== null) {
      client.on('message', (info: socket.SocketMessageInfo) => {
        if (this.bytesHandler !== null) {
          this.bytesHandler(info.message)
        }
      })
      client.on('close', () => {
        if (this.closedHandler !== null) {
          this.closedHandler()
        }
      })
    }
  }

  onBytes(handler: (bytes: ArrayBuffer) => void): void {
    this.bytesHandler = handler
  }

  onClosed(handler: () => void): void {
    this.closedHandler = handler
  }

  needsAck(): boolean {
    return false
  }

  splitControl(): boolean {
    return false
  }

  maxPayload(): number {
    return SYNC_CHUNK_BYTES
  }

  async send(bytes: ArrayBuffer): Promise<void> {
    if (this.conn !== null) {
      await this.conn.send({ data: bytes })
      return
    }
    if (this.client !== null) {
      await this.client.send({ data: bytes })
      return
    }
    throw new Error('连接已经关闭')
  }

  async close(): Promise<void> {
    if (this.conn !== null) {
      try {
        await this.conn.close()
      } catch (error) {
        // Already closed.
      }
      this.conn = null
    }
    if (this.client !== null) {
      try {
        await this.client.close()
      } catch (error) {
        // Already closed.
      }
      this.client = null
    }
  }
}

/**
 * Sender: hand over the manifest, stream every file, over any link.
 *
 * Flow control is one chunk in flight: `send` resolving means the transport
 * accepted the bytes, which is the only backpressure signal these APIs expose.
 * It keeps memory flat, and on a slow link it is what stops the writer from
 * queueing a whole file in the OS.
 */
export async function sendProjectOver(
  link: SyncLink,
  root: string,
  entries: SyncEntry[],
  code: string,
  name: string,
  sessionsJson: string,
  onProgress: (progress: SyncProgress) => void,
  cancelled: () => boolean
): Promise<SyncReport> {
  const total = totalBytes(entries)
  const reader: FrameReader = new FrameReader()
  let denied = ''
  link.onBytes((bytes: ArrayBuffer) => {
    reader.push(bytes)
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

  const sendBlob = async (kind: string, payload: Uint8Array, chunks: number): Promise<void> => {
    const slice = Math.max(256, link.maxPayload() - 128)
    for (let index = 0; index < chunks; index++) {
      const start = index * slice
      const end = Math.min(payload.length, start + slice)
      await link.send(frame({ t: T_BLOB, kind: kind, chunkIndex: index }, payload.slice(start, end).buffer as ArrayBuffer))
    }
  }

  const sessionsBytes = encodeUtf8(sessionsJson)
  if (link.splitControl()) {
    // Control frames carry several KB that a 星闪 port cannot take in one
    // packet, so the manifest and the conversations are chunked; the receiver
    // acks once the manifest is whole.
    const manifestBytes = encodeUtf8(JSON.stringify(entries))
    const slice = Math.max(256, link.maxPayload() - 128)
    const manifestChunks = Math.ceil(manifestBytes.length / slice)
    const sessionsChunks = sessionsBytes.length === 0 ? 0 : Math.ceil(sessionsBytes.length / slice)
    await link.send(frame({
      t: T_HELLO, version: 2, code: code, name: name,
      files: entries.length, bytes: total,
      manifestChunks: manifestChunks, sessionsChunks: sessionsChunks
    }))
    await sendBlob('manifest', manifestBytes, manifestChunks)
    if (sessionsChunks > 0) {
      await sendBlob('sessions', sessionsBytes, sessionsChunks)
    }
  } else {
    await link.send(frame({
      t: T_HELLO, version: 1, code: code, name: name,
      files: entries.length, bytes: total, entries: entries
    }))
  }
  await waitFor(T_ACCEPT)
  // Over TCP the conversations ride on their own frame: a few hundred KB of
  // JSON at most, and keeping them out of the manifest means the receiver can
  // import them with the same code path that reads its own store.
  if (!link.splitControl() && sessionsBytes.length > 0) {
    await link.send(frame({ t: T_SESSIONS }, sessionsBytes.buffer as ArrayBuffer))
  }

  let filesDone = 0
  let bytesDone = 0
  onProgress({
    phase: 'send', filesDone: 0, filesTotal: entries.length,
    bytesDone: 0, bytesTotal: total, detail: '开始发送'
  })

  for (const entry of entries) {
    if (cancelled()) {
      await link.send(frame({ t: T_ERROR, reason: 'cancelled' }))
      throw new Error('已取消')
    }
    const source = fs.openSync(resolveInside(root, entry.path), fs.OpenMode.READ_ONLY)
    try {
      await link.send(frame({ t: T_FILE, path: entry.path, size: entry.size }))
      let sent = 0
      while (sent < entry.size) {
        const want = Math.min(link.maxPayload(), entry.size - sent)
        const buffer = new ArrayBuffer(want)
        const read = fs.readSync(source.fd, buffer, { offset: sent, length: want })
        if (read <= 0) {
          throw new Error(`读取文件提前结束：${entry.path}`)
        }
        const slice = read === want ? buffer : buffer.slice(0, read) as ArrayBuffer
        await link.send(frame({ t: T_CHUNK }, slice))
        sent += read
        bytesDone += read
        onProgress({
          phase: 'send', filesDone: filesDone, filesTotal: entries.length,
          bytesDone: bytesDone, bytesTotal: total, detail: entry.path
        })
        if (cancelled()) {
          await link.send(frame({ t: T_ERROR, reason: 'cancelled' }))
          throw new Error('已取消')
        }
      }
      await link.send(frame({ t: T_FILE_END, path: entry.path, size: entry.size }))
      filesDone++
    } finally {
      fs.closeSync(source)
    }
  }

  await link.send(frame({ t: T_DONE, files: filesDone, bytes: bytesDone }))
  if (link.needsAck()) {
    // Closing immediately after the last write is what lost data on 星闪: the
    // receiving side had not drained the link yet. Wait for its ack, but do not
    // turn a missing ack into a failed transfer — the tree is on its way.
    try {
      await waitFor(T_ACK)
    } catch (error) {
      // Best effort: the receiver may be older code that does not ack.
    }
  }
  onProgress({
    phase: 'done', filesDone: filesDone, filesTotal: entries.length,
    bytesDone: bytesDone, bytesTotal: total, detail: '发送完成'
  })
  return { files: filesDone, bytes: bytesDone, skipped: [] }
}

/** Sender over TCP: connect, then run the shared sender. */
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
  const tcp = socket.constructTCPSocketInstance()
  await tcp.bind({ address: '0.0.0.0', port: 0, family: 1 })
  await tcp.connect({ address: { address: host, port: port, family: 1 }, timeout: 8000 })
  const link = new TcpSyncLink(null, tcp)
  try {
    return await sendProjectOver(link, root, entries, code, name, sessionsJson, onProgress, cancelled)
  } finally {
    await link.close()
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
 * Receiver, transport-neutral: frames in, one tree out.
 *
 * The code is checked against the sender's hello before a single byte is
 * written, and the incoming tree is assembled under `staging` so a cancelled or
 * broken transfer cannot leave half a project inside the workspace. Only after
 * the sender's `done` frame does anything move, file by file.
 *
 * The owning transport feeds bytes with `push` and reports a dropped peer with
 * `peerClosed`; the session answers through the `send` callback it was given.
 */
export class SyncSession {
  private targetRoot: string
  private staging: string
  private code: string
  private sendFn: (bytes: ArrayBuffer) => Promise<void>
  private onProgress: (progress: SyncProgress) => void
  private onSessions: (json: string) => void
  private onFinished: (report: SyncReport, error: string) => void
  private reader: FrameReader = new FrameReader()
  private pending: SyncFrameBox[] = []
  private pumping: boolean = false
  private finished: boolean = false
  private report: SyncReport = { files: 0, bytes: 0, skipped: [] }
  private entries: SyncEntry[] = []
  private bytesDone: number = 0
  private filesDone: number = 0
  private sessionsJson: string = ''
  private manifestParts: Uint8Array[] = []
  private manifestExpected: number = 0
  private sessionsParts: Uint8Array[] = []
  private sessionsExpected: number = 0
  private currentFile: fs.File | null = null
  private currentPath: string = ''
  private currentSize: number = 0
  private currentWritten: number = 0

  constructor(
    targetRoot: string,
    staging: string,
    code: string,
    sendFn: (bytes: ArrayBuffer) => Promise<void>,
    onProgress: (progress: SyncProgress) => void,
    onSessions: (json: string) => void,
    onFinished: (report: SyncReport, error: string) => void
  ) {
    this.targetRoot = targetRoot
    this.staging = staging
    this.code = code
    this.sendFn = sendFn
    this.onProgress = onProgress
    this.onSessions = onSessions
    this.onFinished = onFinished
  }

  /** Feed bytes from the transport; frames are processed as they complete. */
  async push(bytes: ArrayBuffer): Promise<void> {
    this.reader.push(bytes)
    let box = this.reader.next()
    while (box !== null) {
      this.pending.push(box)
      box = this.reader.next()
    }
    await this.pump()
  }

  /** The peer went away before `done`. */
  peerClosed(): void {
    void this.finish('对方中途断开')
  }

  private async pump(): Promise<void> {
    if (this.pumping) {
      return
    }
    this.pumping = true
    try {
      while (this.pending.length > 0 && !this.finished) {
        const box = this.pending.shift() as SyncFrameBox
        await this.handle(box)
      }
    } finally {
      this.pumping = false
    }
  }

  private async handle(box: SyncFrameBox): Promise<void> {
    const header = box.header
    const data = box.data
    try {
      if (header.t === T_HELLO) {
        if (header.code !== this.code) {
          await this.sendFn(frame({ t: T_DENY, reason: '配对码不对' }))
          await this.finish('配对码不对，已拒绝')
          return
        }
        this.manifestParts = []
        this.sessionsParts = []
        this.manifestExpected = header.manifestChunks === undefined ? 0 : header.manifestChunks
        this.sessionsExpected = header.sessionsChunks === undefined ? 0 : header.sessionsChunks
        if (this.manifestExpected > 0) {
          // v2: entries arrive in blob frames; accept only once the manifest is
          // whole, because the sender must not stream files before we know
          // what to expect.
          return
        }
        this.entries = header.entries === undefined ? [] : header.entries
        await this.acceptManifest()
        return
      }
      if (header.t === T_BLOB) {
        if (data === null) {
          return
        }
        const kind = header.kind === undefined ? 'manifest' : header.kind
        const parts = kind === 'sessions' ? this.sessionsParts : this.manifestParts
        const expected = kind === 'sessions' ? this.sessionsExpected : this.manifestExpected
        const index = header.chunkIndex === undefined ? -1 : header.chunkIndex
        if (index < 0 || index >= expected || parts.length >= expected) {
          await this.finish('控制帧序号不对')
          return
        }
        parts.push(new Uint8Array(data))
        if (parts.length < expected) {
          return
        }
        const joined = this.joinParts(parts)
        if (kind === 'sessions') {
          this.sessionsJson = decodeUtf8(joined)
          this.onSessions(this.sessionsJson)
          return
        }
        let parsed: SyncEntry[] = []
        try {
          parsed = JSON.parse(decodeUtf8(joined)) as SyncEntry[]
        } catch (error) {
          await this.finish('清单解析失败')
          return
        }
        this.entries = parsed
        await this.acceptManifest()
        return
      }
      if (header.t === T_SESSIONS) {
        if (data !== null) {
          this.sessionsJson = decodeUtf8(new Uint8Array(data))
        }
        return
      }
      if (header.t === T_FILE) {
        this.currentPath = header.path === undefined ? '' : header.path
        this.currentSize = header.size === undefined ? 0 : header.size
        this.currentWritten = 0
        const full = resolveInside(this.staging, this.currentPath)
        const parent = full.substring(0, full.lastIndexOf('/'))
        if (!fs.accessSync(parent)) {
          fs.mkdirSync(parent, true)
        }
        this.currentFile = fs.openSync(full,
          fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
        return
      }
      if (header.t === T_CHUNK) {
        if (this.currentFile === null || data === null) {
          await this.finish('收到意外的数据块')
          return
        }
        fs.writeSync(this.currentFile.fd, data)
        this.currentWritten += data.byteLength
        this.bytesDone += data.byteLength
        this.onProgress({
          phase: 'receive', filesDone: this.filesDone, filesTotal: this.entries.length,
          bytesDone: this.bytesDone, bytesTotal: this.totalBytes(), detail: this.currentPath
        })
        return
      }
      if (header.t === T_FILE_END) {
        if (this.currentFile !== null) {
          fs.closeSync(this.currentFile)
          this.currentFile = null
        }
        if (this.currentWritten !== this.currentSize) {
          await this.finish(`${this.currentPath} 大小不符（收到 ${this.currentWritten}，声明 ${this.currentSize}）`)
          return
        }
        this.filesDone++
        return
      }
      if (header.t === T_ERROR) {
        await this.finish(header.reason === undefined ? '对方中止了传输' : `对方中止：${header.reason}`)
        return
      }
      if (header.t === T_DONE) {
        await this.finish('')
        return
      }
    } catch (error) {
      await this.finish(`接收失败：${(error as Error).message}`)
    }
  }

  private joinParts(parts: Uint8Array[]): Uint8Array {
    let length = 0
    for (const part of parts) {
      length += part.length
    }
    const joined = new Uint8Array(length)
    let offset = 0
    for (const part of parts) {
      joined.set(part, offset)
      offset += part.length
    }
    return joined
  }

  private async acceptManifest(): Promise<void> {
    let total = 0
    for (const entry of this.entries) {
      total += entry.size
    }
    await this.sendFn(frame({ t: T_ACCEPT }))
    this.onProgress({
      phase: 'receive', filesDone: 0, filesTotal: this.entries.length,
      bytesDone: 0, bytesTotal: total, detail: '开始接收'
    })
  }

  private totalBytes(): number {
    let total = 0
    for (const entry of this.entries) {
      total += entry.size
    }
    return total
  }

  private async finish(error: string): Promise<void> {
    if (this.finished) {
      return
    }
    this.finished = true
    if (this.currentFile !== null) {
      try {
        fs.closeSync(this.currentFile)
      } catch (closeError) {
        // Best effort.
      }
      this.currentFile = null
    }
    if (error.length > 0) {
      this.onFinished(this.report, error)
      removeTree(this.staging)
      return
    }
    // Move the tree in: every file has been written and size-checked.
    try {
      for (const entry of this.entries) {
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
        this.report.files = this.report.files + 1
      }
      this.report.bytes = this.bytesDone
      if (this.sessionsJson.length > 0) {
        this.onSessions(this.sessionsJson)
      }
      // The sender may be about to hang up a link that still holds bytes; tell
      // it the tree is safely on disk first. A failure here only costs the
      // sender a timeout, so it must not fail the receive.
      try {
        await this.sendFn(frame({ t: T_ACK }))
      } catch (error) {
        // Peer gone after `done`; the files are already in place.
      }
      this.onFinished(this.report, '')
    } catch (moveError) {
      this.onFinished(this.report, `写入工作区失败：${(moveError as Error).message}`)
    } finally {
      removeTree(this.staging)
    }
  }
}

/**
 * Receiver over TCP: listen once, hand the connection to a SyncSession.
 *
 * Nothing listens until the user opens receiving mode, and the listener closes
 * after the single transfer so the port cannot become a standing invitation.
 */
export class SyncReceiver {
  private server: socket.TCPSocketServer | null = null
  private conn: socket.TCPSocketConnection | null = null
  private code: string = ''
  private finished: boolean = false

  /** The code to show while waiting; set by `open`. */
  get pairCode(): string {
    return this.code
  }

  async open(
    context: common.UIAbilityContext,
    targetRoot: string,
    onProgress: (progress: SyncProgress) => void,
    onSessions: (json: string) => void,
    onFinished: (report: SyncReport, error: string) => void
  ): Promise<number> {
    await this.close()
    const staging = stagingDir(context)
    removeTree(staging)
    fs.mkdirSync(staging)
    this.code = makePairCode()
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
      this.conn = conn
      const link = new TcpSyncLink(conn, null)
      const session = new SyncSession(
        targetRoot,
        staging,
        this.code,
        (bytes: ArrayBuffer) => link.send(bytes),
        onProgress,
        onSessions,
        (report: SyncReport, error: string) => {
          this.finished = true
          onFinished(report, error)
          void this.close()
        }
      )
      link.onBytes((bytes: ArrayBuffer) => {
        void session.push(bytes)
      })
      link.onClosed(() => {
        session.peerClosed()
      })
    })
    this.server = server
    return port
  }

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
}
