import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { socket } from '@kit.NetworkKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { connection } from '@kit.NetworkKit'
import { webSocket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import deviceInfo from '@ohos.deviceInfo'
import { dataShare } from '@kit.ArkData'
import { dataTransfer } from '@kit.NearLinkKit'

/**
 * Interop: talking to something that is not this app's own runtime.
 *
 * Every channel here carries the same envelope, so the UI does not care which
 * wire is underneath. That is the whole point of this file: the interesting
 * question is never "can we open a socket", it is "who is on the other end and
 * do they trust us". Transports differ; the message does not.
 *
 * Framing is one JSON object per line, the same convention the ACP bridge uses,
 * because that is already proven to survive partial reads on this platform.
 */

export enum ChannelKind {
  LAN = 'lan',
  WEBSOCKET = 'websocket',
  CLIPBOARD = 'clipboard',
  DISTRIBUTED = 'distributed',
  BLUETOOTH = 'bluetooth',
  NEARLINK = 'nearlink'
}

/** One line on the wire. `v` exists so a future change can be detected. */
export interface InteropEnvelope {
  v: number
  id: string
  from: string
  at: number
  text: string
}

/** Whether a channel can be used right now, and why not when it cannot. */
export interface ChannelStatus {
  kind: ChannelKind
  label: string
  available: boolean
  /** Short reason shown next to the row: what is missing, not what failed. */
  note: string
}

export const INTEROP_PORT: number = 4518
const ENVELOPE_VERSION: number = 1

/** Build an envelope; ids are time-ordered so a log reads in send order. */
export function makeEnvelope(from: string, text: string, at: number): InteropEnvelope {
  return {
    v: ENVELOPE_VERSION,
    id: `${at.toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`,
    from: from,
    at: at,
    text: text
  }
}

/** One envelope as a framed line (trailing newline included). */
export function encodeEnvelope(envelope: InteropEnvelope): string {
  return `${JSON.stringify(envelope)}\n`
}

/**
 * Parse one line. Returns null for anything that is not a well-formed envelope
 * of this version — a peer running a different build must not crash the reader,
 * and a half-received line must not be mistaken for a message.
 */
export function decodeEnvelope(line: string): InteropEnvelope | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) {
    return null
  }
  try {
    const raw = JSON.parse(trimmed) as Record<string, Object>
    const version = raw.v as number
    if (version !== ENVELOPE_VERSION) {
      return null
    }
    const id = raw.id as string
    const from = raw.from as string
    const at = raw.at as number
    const text = raw.text as string
    if (typeof id !== 'string' || typeof from !== 'string' ||
      typeof text !== 'string' || typeof at !== 'number') {
      return null
    }
    return { v: version, id: id, from: from, at: at, text: text }
  } catch (error) {
    return null
  }
}

/**
 * Split a growing buffer into complete lines, keeping the remainder.
 *
 * A TCP read is not a message boundary: one `on('message')` can carry half a
 * line, three lines, or a line and a half. Every channel needs this, so it
 * lives here rather than inside the LAN transport.
 */
export function takeLines(buffer: string): string[] {
  const out: string[] = []
  let rest = buffer
  let index = rest.indexOf('\n')
  while (index >= 0) {
    out.push(rest.substring(0, index))
    rest = rest.substring(index + 1)
    index = rest.indexOf('\n')
  }
  return out
}

/** The trailing partial line after `takeLines` consumed every complete one. */
export function keepRemainder(buffer: string): string {
  const index = buffer.lastIndexOf('\n')
  return index < 0 ? buffer : buffer.substring(index + 1)
}

/**
 * What this device can do, decided by the system capability query rather than
 * by a build flag: the same HAP ships to phones with and without 星闪.
 */
export function probeChannels(): ChannelStatus[] {
  return [
    {
      kind: ChannelKind.LAN,
      label: '同一 WiFi 直连',
      available: true,
      note: `端口 ${INTEROP_PORT}，不需要账号、不经过服务器`
    },
    {
      kind: ChannelKind.WEBSOCKET,
      label: '中继服务器',
      available: true,
      note: '需要填写中继地址；跨网络、跨账号可用'
    },
    {
      kind: ChannelKind.CLIPBOARD,
      label: '剪贴板',
      available: true,
      note: '手动复制，同一设备内的任意应用'
    },
    {
      kind: ChannelKind.DISTRIBUTED,
      label: '同账号设备',
      available: canIUse('SystemCapability.DistributedDataManager.DataObject.DistributedObject'),
      note: '只在你自己的、同一华为账号的可信设备之间'
    },
    {
      kind: ChannelKind.BLUETOOTH,
      label: '蓝牙近场',
      available: canIUse('SystemCapability.Communication.Bluetooth.Core'),
      note: '双方都要装本应用，十米内'
    },
    {
      kind: ChannelKind.NEARLINK,
      label: '星闪近场',
      available: canIUse('SystemCapability.Communication.NearLink.Base'),
      note: '需要支持星闪的机型'
    }
  ]
}

/** Who we are on the wire: a short local name the user can recognise. */
export function localPeerName(): string {
  const model = deviceInfoModel()
  return model.length > 0 ? model : '本机'
}

function deviceInfoModel(): string {
  try {
    // Display only: a device that will not tell us its model is still allowed
    // to connect, it just shows up as 本机.
    const model = deviceInfo.productModel
    return typeof model === 'string' ? model : ''
  } catch (error) {
    return ''
  }
}

/** Callbacks one channel must serve to be usable by the panel. */
export interface ChannelHandlers {
  onPeer: (peer: string) => void
  onMessage: (envelope: InteropEnvelope) => void
  onError: (reason: string) => void
}

/**
 * LAN channel: one host, one guest, plain TCP on the local network.
 *
 * Deliberately one-to-one. A room that accepts strangers would need identity,
 * which is exactly the part we do not have on a LAN — so the UI asks the user
 * to read out an address instead of pretending there is a directory.
 */
export class LanChannel {
  private server: socket.TCPSocketServer | null = null
  private client: socket.TCPSocket | null = null
  private conn: socket.TCPSocketConnection | null = null
  private buffer: string = ''
  private handlers: ChannelHandlers
  private peer: string = ''

  constructor(handlers: ChannelHandlers) {
    this.handlers = handlers
  }

  /** Start listening; resolves with the port actually bound. */
  async host(): Promise<number> {
    await this.close()
    const server = socket.constructTCPSocketServerInstance()
    await server.listen({ address: '0.0.0.0', port: INTEROP_PORT, family: 1 })
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.attach(conn)
    })
    this.server = server
    return INTEROP_PORT
  }

  /** Join a host; the address is `ip` or `ip:port`. */
  async join(address: string): Promise<void> {
    await this.close()
    const parts = address.trim().split(':')
    const host = parts[0]
    const port = parts.length > 1 ? Number(parts[1]) : INTEROP_PORT
    if (host.length === 0 || Number.isNaN(port)) {
      throw new Error('地址格式应为 192.168.1.5 或 192.168.1.5:4518')
    }
    const tcp = socket.constructTCPSocketInstance()
    await tcp.bind({ address: '0.0.0.0', port: 0, family: 1 })
    await tcp.connect({ address: { address: host, port: port, family: 1 }, timeout: 8000 })
    this.client = tcp
    this.peer = host
    this.buffer = ''
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.consume(info.message)
    })
    this.handlers.onPeer(host)
  }

  private attach(conn: socket.TCPSocketConnection): void {
    this.conn = conn
    this.buffer = ''
    conn.on('message', (info: socket.SocketMessageInfo) => {
      this.consume(info.message)
    })
    conn.on('close', () => {
      this.handlers.onPeer('')
    })
    this.peer = '对方设备'
    this.handlers.onPeer(this.peer)
  }

  private consume(data: ArrayBuffer): void {
    const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(data))
    this.buffer += text
    for (const line of takeLines(this.buffer)) {
      const envelope = decodeEnvelope(line)
      if (envelope !== null) {
        this.handlers.onMessage(envelope)
      }
    }
    this.buffer = keepRemainder(this.buffer)
  }

  async send(envelope: InteropEnvelope): Promise<void> {
    const bytes = new util.TextEncoder().encodeInto(encodeEnvelope(envelope))
    if (this.conn !== null) {
      await this.conn.send({ data: bytes })
      return
    }
    if (this.client !== null) {
      await this.client.send({ data: bytes })
      return
    }
    throw new Error('还没有连接')
  }

  connected(): boolean {
    return this.conn !== null || this.client !== null
  }

  async close(): Promise<void> {
    this.buffer = ''
    this.peer = ''
    try {
      if (this.conn !== null) {
        await this.conn.close()
      }
    } catch (error) {
      // Closing a peer that already vanished is not an error worth reporting.
    }
    try {
      if (this.client !== null) {
        await this.client.close()
      }
    } catch (error) {
    }
    try {
      if (this.server !== null) {
        await this.server.off('connect')
        await this.server.close()
      }
    } catch (error) {
    }
    this.conn = null
    this.client = null
    this.server = null
  }
}

/** WebSocket channel: same envelope, but over a relay the user configures. */
export class WebSocketChannel {
  private ws: webSocket.WebSocket | null = null
  private buffer: string = ''
  private handlers: ChannelHandlers

  constructor(handlers: ChannelHandlers) {
    this.handlers = handlers
  }

  async connect(url: string): Promise<void> {
    await this.close()
    const ws = webSocket.createWebSocket()
    ws.on('message', (err: Error, value: string | ArrayBuffer) => {
      if (typeof value === 'string') {
        this.consume(value)
      }
    })
    ws.on('open', () => {
      this.handlers.onPeer(url)
    })
    ws.on('error', (err: Error) => {
      this.handlers.onError(err.message)
    })
    await ws.connect(url)
    this.ws = ws
  }

  private consume(chunk: string): void {
    this.buffer += chunk
    for (const line of takeLines(this.buffer)) {
      const envelope = decodeEnvelope(line)
      if (envelope !== null) {
        this.handlers.onMessage(envelope)
      }
    }
    this.buffer = keepRemainder(this.buffer)
  }

  async send(envelope: InteropEnvelope): Promise<void> {
    if (this.ws === null) {
      throw new Error('还没有连接')
    }
    await this.ws.send(encodeEnvelope(envelope))
  }

  async close(): Promise<void> {
    this.buffer = ''
    if (this.ws !== null) {
      try {
        await this.ws.close()
      } catch (error) {
      }
      this.ws = null
    }
  }
}

/**
 * Clipboard channel: no connection at all.
 *
 * It exists because "copy this, paste there" is the one cross-app handoff that
 * works without any permission, any account, or the other app's cooperation —
 * and on a phone it is often what the user actually wants.
 */
export class ClipboardChannel {
  static async copy(text: string): Promise<void> {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
    await pasteboard.getSystemPasteboard().setData(data)
  }

  static async paste(): Promise<string> {
    const data = await pasteboard.getSystemPasteboard().getData()
    return data.getPrimaryText()
  }
}

/**
 * Result of actually trying a channel, not of asking whether it should work.
 *
 * This exists because canIUse answers "does the system advertise the
 * capability", which is a different question from "can this app open it". The
 * only honest way to tell them apart is to make the call and report the code.
 */
export interface ProbeResult {
  kind: ChannelKind
  ok: boolean
  detail: string
}

/**
 * Ask for ACCESS_NEARLINK once; `true` when it is granted.
 *
 * The system shows nothing when the answer is already yes, so a denied
 * permission surfaces as false rather than as a dialog on every tap.
 */
export async function requestNearLinkPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const manager = abilityAccessCtrl.createAtManager()
    const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_NEARLINK'])
    return result.authResults.length > 0 && result.authResults[0] === 0
  } catch (error) {
    return false
  }
}

/**
 * Try 星闪 for real: create a port, then tear it down.
 *
 * A port is the cheap half of the API — no pairing, no peer, no scanning. If
 * even that fails, the rest of the chain is moot, and we learn it in one call.
 */
export async function probeNearLink(context: common.UIAbilityContext): Promise<ProbeResult> {
  if (!canIUse('SystemCapability.Communication.NearLink.Core')) {
    return { kind: ChannelKind.NEARLINK, ok: false, detail: '本机没有星闪 syscap' }
  }
  // ACCESS_NEARLINK is user_grant: until the user answers the dialog, createPort
  // answers 201 Permission denied. Asking here is what makes the probe report
  // "user said no" instead of "platform does not have it".
  const granted = await requestNearLinkPermission(context)
  if (!granted) {
    return { kind: ChannelKind.NEARLINK, ok: false, detail: '用户未授予星闪权限（ACCESS_NEARLINK）' }
  }
  try {
    // A fixed UUID identifies our service on the star-flash link; the same
    // string must be used by the peer, so it is a constant, not a random id.
    dataTransfer.createPort(NEARLINK_SERVICE_UUID)
  } catch (error) {
    const err = error as Record<string, Object>
    const code = err.code === undefined ? '' : ` ${err.code}`
    const message = err.message === undefined ? '未知错误' : err.message as string
    return { kind: ChannelKind.NEARLINK, ok: false, detail: `createPort 失败${code}：${message}` }
  }
  // Tearing down is the second half of the probe, but a failure there must not
  // turn a successful port creation into "unavailable": the channel works, the
  // cleanup merely did not.
  let cleanup = ''
  try {
    dataTransfer.destroyPort(NEARLINK_SERVICE_UUID)
  } catch (error) {
    const err = error as Record<string, Object>
    cleanup = err.code === undefined ? '（销毁未确认）' : `（销毁 ${err.code}）`
  }
  return {
    kind: ChannelKind.NEARLINK,
    ok: true,
    detail: `端口创建成功（可继续做配对与传输）${cleanup}`
  }
}

/**
 * Fixed service identity for the 星闪 port channel.
 *
 * 36-character 8-4-4-4-12 form on purpose: `createPort` documents the custom
 * uuid as "16 bytes like FFFFFFFF-FC70-11EA-B720-000078951234" and rejects a
 * bare 32-character hex string with 401 Invalid parameter — which is exactly
 * what the first version of this probe sent, so it reported the channel as
 * unavailable while the fault was here.
 */
export const NEARLINK_SERVICE_UUID: string = '6E656172-4C69-6E6B-0000-000000453931'

/**
 * Try DataShare for real: open the proxy handle our own bundle publishes to.
 *
 * The failure here is expected to be honest and specific — "no publisher" is a
 * different answer from "denied", and only the call can tell us which.
 */
export async function probeDataShare(bundleName: string): Promise<ProbeResult> {
  // Shared configurations live under `datashareproxy://<bundle>/<path>`, not
  // under `datashare:///...` (that scheme addresses a DataShare extension's
  // table). The first probe used the wrong scheme and read a URI that could
  // never exist, so it blamed the platform for its own mistake.
  const uri = `datashareproxy://${bundleName}/interop-probe`
  const config: dataShare.DataProxyConfig = { type: dataShare.DataProxyType.SHARED_CONFIG }
  let handle: dataShare.DataProxyHandle | null = null
  try {
    handle = await dataShare.createDataProxyHandle()
  } catch (error) {
    const err = error as Record<string, Object>
    const code = err.code === undefined ? '' : ` ${err.code}`
    return { kind: ChannelKind.CLIPBOARD, ok: false, detail: `createDataProxyHandle 失败${code}` }
  }
  // Publish one short-lived value, read it back, then delete it: the readable
  // half of the API is only meaningful once the app has published something.
  // Each stage names itself in the failure text, because 15700014 alone does
  // not say whether the URI, the value or the array was rejected.
  try {
    const published = await handle.publish([{ uri: uri, value: 'probe' }], config)
    if (published.length === 0 || published[0].result !== dataShare.DataProxyErrorCode.SUCCESS) {
      const result = published.length === 0 ? '无返回' : `结果 ${published[0].result}`
      return { kind: ChannelKind.CLIPBOARD, ok: false, detail: `发布共享配置失败（${uri}）：${result}` }
    }
  } catch (error) {
    const err = error as Record<string, Object>
    const code = err.code === undefined ? '' : ` ${err.code}`
    const message = err.message === undefined ? '未知错误' : err.message as string
    return { kind: ChannelKind.CLIPBOARD, ok: false, detail: `发布失败${code}（uri=${uri}）：${message}` }
  }
  // `getValues` only serves multi-value records; a single-value config is read
  // back with `get`, which answers per URI. Using the wrong one of the pair
  // fails as 15700014 "parameter format is incorrect" — a message that sends
  // you looking at the URI instead of at the call.
  let readBack = ''
  try {
    const results = await handle.get([uri], config)
    if (results.length === 0 || results[0].result !== dataShare.DataProxyErrorCode.SUCCESS) {
      const result = results.length === 0 ? '无返回' : `结果 ${results[0].result}`
      return { kind: ChannelKind.CLIPBOARD, ok: false, detail: `读回失败（${uri}）：${result}` }
    }
    readBack = results[0].value === undefined ? '（空值）' : String(results[0].value)
  } catch (error) {
    const err = error as Record<string, Object>
    const code = err.code === undefined ? '' : ` ${err.code}`
    const message = err.message === undefined ? '未知错误' : err.message as string
    return { kind: ChannelKind.CLIPBOARD, ok: false, detail: `读回失败${code}（uri=${uri}）：${message}` }
  }
  try {
    await handle.delete([uri], config)
  } catch (error) {
    // Leaving one probe entry behind is not worth failing the probe for.
  }
  return {
    kind: ChannelKind.CLIPBOARD,
    ok: true,
    detail: `共享配置可用（发布 + 读回「${readBack}」，已清理）`
  }
}

/** The device's own LAN address, for showing a joinable code. */
export async function localLanAddress(): Promise<string> {
  try {
    const net = await connection.getDefaultNet()
    if (net.netId === 0) {
      return ''
    }
    const props = await connection.getConnectionProperties(net)
    for (const link of props.linkAddresses) {
      const address = link.address.address
      // IPv4 only: an IPv6 literal is unusable as something to read aloud.
      if (address.indexOf('.') > 0) {
        return address
      }
    }
  } catch (error) {
    return ''
  }
  return ''
}
