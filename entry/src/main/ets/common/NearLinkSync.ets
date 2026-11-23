import { advertising, constant, dataTransfer, scan } from '@kit.NearLinkKit'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { requestNearLinkPermission } from './Interop'
import { removeTree, SyncLink, SyncProgress, SyncReport, SyncSession } from './ProjectSync'

/**
 * 星闪 (NearLink) as a second transport for project sync.
 *
 * The protocol does not change: frames are the same bytes, chunks are 32KB
 * (well inside the 65535-byte port MTU), and SyncSession handles both ends once
 * bytes arrive. This file only teaches the transport what "a peer" and "a
 * packet" mean: scan/advertise to find each other, one port channel for data,
 * writeData per chunk, readData for the other direction.
 *
 * Two things are inherent to 星闪 and are surfaced rather than hidden:
 *   · both devices must have the app and support the radio — there is no way to
 *     send to a device that is not running the same service;
 *   · the channel is short-range and pairing is a system dialog, so the first
 *     connect can put a box on both screens.
 *
 * Status: the scan/advertise/port half is exercised on a single device (see
 * docs/PROJECT-SYNC.md). The end-to-end byte path needs two 星闪-capable
 * devices and is verified when a second one is plugged in.
 */

/** Service identity of the sync channel; must match on both sides. */
export const NEARLINK_SYNC_UUID: string = '7D5F6A2C-1B8E-4C3A-9F10-2A6B7C8D9E01'

/** Requested packet size; the port negotiates down if the peer wants less. */
const NEARLINK_MTU: number = 65535

/**
 * Chunk ceiling for 星闪.
 *
 * Not the protocol's 32KB: on hardware the negotiated size came back as 0 and
 * a 32KB write was delivered as ~7.2KB with the link dropping, while 4KB
 * packets are small enough to go through whatever the stack picked.
 */
const SYNC_NEARLINK_CHUNK_BYTES: number = 4 * 1024

/**
 * A place to put facts the radio will not tell us through the API.
 *
 * The 星闪 events are all-or-nothing from the caller's side: a refused packet
 * and a peer that never answered look the same, so the transport records what
 * it actually did. The test harness points this at a file it can pull.
 */
export type NearLinkLog = (line: string) => void

let logSink: NearLinkLog = (_line: string) => {}

export function setNearLinkLog(sink: NearLinkLog): void {
  logSink = sink
}

/** Record one transport fact; never throws into the caller. */
export function nearLinkLog(line: string): void {
  try {
    logSink(line)
  } catch (error) {
    // A diagnostics sink must not break the transport.
  }
}

/** One device seen by the scanner. */
export interface NearLinkPeer {
  address: string
  name: string
  rssi: number
}

/** Whether this device can run the 星闪 sync channel at all. */
export function nearLinkSyncSupported(): boolean {
  try {
    if (!canIUse('SystemCapability.Communication.NearLink.Core')) {
      return false
    }
    return true
  } catch (error) {
    return false
  }
}

/**
 * Scan for nearby 星闪 devices.
 *
 * No filters: the point is to show a list the user can pick from, and filtering
 * on our service uuid belongs in advertising data, not in a scan the user may
 * want for other reasons. The result is whatever answered inside the window.
 */
export async function scanNearLinkPeers(durationMs: number): Promise<NearLinkPeer[]> {
  const peers: NearLinkPeer[] = []
  const seen: string[] = []
  const onFound = (results: scan.ScanResults[]): void => {
    for (const result of results) {
      if (result.address.length === 0 || seen.includes(result.address)) {
        continue
      }
      seen.push(result.address)
      peers.push({
        address: result.address,
        name: result.deviceName.length > 0 ? result.deviceName : result.address,
        rssi: result.rssi
      })
    }
  }
  scan.on('deviceFound', onFound)
  try {
    await scan.startScan(null, { scanMode: scan.ScanMode.SCAN_MODE_BALANCED })
    await new Promise<void>((resolve) => setTimeout(resolve, durationMs))
  } finally {
    try {
      await scan.stopScan()
    } catch (error) {
      // Already stopped.
    }
    try {
      scan.off('deviceFound', onFound)
    } catch (error) {
      // No listener registered.
    }
  }
  return peers
}

/** Start advertising the sync service so a sender can find us. */
async function startAdvertise(): Promise<number> {
  const params: advertising.AdvertisingParams = {
    advertisingSettings: { isConnectable: true },
    advertisingData: {
      serviceUuids: [NEARLINK_SYNC_UUID],
      includeDeviceName: true
    }
  }
  const id = await advertising.startAdvertising(params)
  nearLinkLog(`recv advertising started id=${id}`)
  return id
}

/**
 * Sender side: connect to one peer and turn `writeData/readData` into a link.
 */
export class NearLinkSyncLink implements SyncLink {
  private address: string
  private bytesHandler: ((bytes: ArrayBuffer) => void) | null = null
  private closedHandler: (() => void) | null = null
  private connected: boolean = false
  private portOpen: boolean = false
  /** Resolved when the port channel reports CONNECTED, not when connect() returns. */
  private mtu: number = NEARLINK_MTU
  /** What the two stacks actually agreed on, from the CONNECTED event. */
  private negotiatedMtu: number = 0
  private readyResolve: () => void = () => {}
  private readyReject: (error: Error) => void = () => {}
  private ready: Promise<void> | null = null
  private readonly onRead = (params: dataTransfer.DataParams): void => {
    if (params.address !== this.address || this.bytesHandler === null) {
      return
    }
    this.bytesHandler(params.data)
  }
  private readonly onState = (result: dataTransfer.ConnectionResult): void => {
    if (result.address !== this.address) {
      return
    }
    const state = result.state
    nearLinkLog(`link state address=${result.address} state=${state}`)
    if (state === constant.ConnectionState.STATE_CONNECTED) {
      // The requested mtu is a wish; the event carries the negotiated one, and
      // writing more than it silently loses the tail of the packet.
      if (result.mtu > 0) {
        this.negotiatedMtu = result.mtu
        nearLinkLog(`link negotiated mtu=${result.mtu}`)
      }
      this.readyResolve()
      return
    }
    if (state === constant.ConnectionState.STATE_DISCONNECTED) {
      this.readyReject(new Error('星闪链路已断开'))
      if (this.closedHandler !== null) {
        this.closedHandler()
      }
    }
  }

  constructor(address: string) {
    this.address = address
  }

  /**
   * Establish the port channel.
   *
   * `mtu` is a parameter because the handshake is the one thing that failed
   * on real hardware before the byte path could be tried: asking for the
   * maximum packet size can be refused outright, while a small one goes
   * through. The protocol's frame size must then stay under whatever was
   * negotiated.
   */
  needsAck(): boolean {
    return true
  }

  maxPayload(): number {
    const negotiated = this.negotiatedMtu > 0 ? this.negotiatedMtu : this.mtu
    return Math.max(256, Math.min(negotiated, SYNC_NEARLINK_CHUNK_BYTES))
  }

  async connect(mtu: number = NEARLINK_MTU): Promise<void> {
    this.mtu = mtu
    // Both ends own the port: the receiver advertises it, and the sender has to
    // have it open locally too before the channel can be established —
    // connecting without it failed with 1009700099 on hardware.
    try {
      dataTransfer.createPort(NEARLINK_SYNC_UUID)
      this.portOpen = true
    } catch (error) {
      // Already created by an earlier attempt; the connect below decides.
    }
    dataTransfer.on('readData', this.onRead)
    dataTransfer.on('connectionStateChanged', this.onState)
    this.ready = new Promise<void>((resolve, reject) => {
      this.readyResolve = resolve
      this.readyReject = reject
    })
    nearLinkLog(`link connect attempt address=${this.address} mtu=${mtu}`)
    try {
      await dataTransfer.connect({ address: this.address, uuid: NEARLINK_SYNC_UUID, mtu: mtu })
    } catch (error) {
      // The stack refuses an oversized packet request outright; step down to
      // sizes that have been seen to work instead of failing the transfer.
      nearLinkLog(`link connect mtu=${mtu} refused ${JSON.stringify(error)}`)
      const fallback = mtu > 1024 ? 1024 : 512
      this.mtu = fallback
      await dataTransfer.connect({ address: this.address, uuid: NEARLINK_SYNC_UUID, mtu: fallback })
    }
    // connect() resolving only means the request was accepted: on hardware the
    // port channel went CONNECTED about ten seconds later, and frames written
    // before that were lost. Wait for the event, and treat the wait as part of
    // the connection.
    let timer = -1
    const timeout = new Promise<void>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('星闪链路没有在 30s 内建立')), 30000)
    })
    try {
      await Promise.race([this.ready, timeout])
    } finally {
      if (timer !== -1) {
        clearTimeout(timer)
      }
    }
    this.connected = true
    nearLinkLog(`link ready address=${this.address} mtu=${mtu}`)
  }

  onBytes(handler: (bytes: ArrayBuffer) => void): void {
    this.bytesHandler = handler
  }

  onClosed(handler: () => void): void {
    this.closedHandler = handler
  }

  async send(bytes: ArrayBuffer): Promise<void> {
    // writeData is per packet; the protocol's 32KB chunk keeps us under the
    // negotiated MTU, and one chunk in flight gives backpressure.
    try {
      await dataTransfer.writeData({ address: this.address, uuid: NEARLINK_SYNC_UUID, data: bytes })
    } catch (error) {
      nearLinkLog(`link write failed bytes=${bytes.byteLength} ${JSON.stringify(error)}`)
      throw new Error((error as Error).message)
    }
  }

  async close(): Promise<void> {
    try {
      dataTransfer.off('readData', this.onRead)
    } catch (error) {
      // No listener registered.
    }
    try {
      dataTransfer.off('connectionStateChanged', this.onState)
    } catch (error) {
      // No listener registered.
    }
    if (this.connected) {
      try {
        await dataTransfer.disconnect({ address: this.address, uuid: NEARLINK_SYNC_UUID })
      } catch (error) {
        // Already gone.
      }
      this.connected = false
    }
    if (this.portOpen) {
      try {
        dataTransfer.destroyPort(NEARLINK_SYNC_UUID)
      } catch (error) {
        // Already destroyed.
      }
      this.portOpen = false
    }
  }
}

/**
 * Receiver side: open a port, advertise, and feed every incoming packet to one
 * SyncSession.
 *
 * The first peer that sends anything becomes the session's peer; the channel is
 * point-to-point in practice because the listener exists only while the user is
 * waiting.
 */
export class NearLinkSyncReceiver {
  private code: string = ''
  private advId: number = -1
  private portOpen: boolean = false
  private peer: string = ''
  private session: SyncSession | null = null
  private finished: boolean = false
  private readonly onRead = (params: dataTransfer.DataParams): void => {
    nearLinkLog(`recv readData from=${params.address} bytes=${params.data.byteLength}`)
    if (this.session === null) {
      return
    }
    this.peer = params.address
    void this.session.push(params.data)
  }
  private readonly onConnState = (result: dataTransfer.ConnectionResult): void => {
    nearLinkLog(`recv connectionState address=${result.address} state=${result.state}`)
    if (result.state === constant.ConnectionState.STATE_CONNECTED) {
      // The connection event carries the peer address even when no payload has
      // arrived yet, which is what a reply needs.
      this.peer = result.address
    }
  }

  get pairCode(): string {
    return this.code
  }

  /** Open the channel; resolves once we are advertising and waiting. */
  async open(
    context: common.UIAbilityContext,
    targetRoot: string,
    code: string,
    onProgress: (progress: SyncProgress) => void,
    onSessions: (json: string) => void,
    onFinished: (report: SyncReport, error: string) => void
  ): Promise<void> {
    await this.close()
    this.code = code
    this.finished = false
    this.peer = ''
    const staging = `${context.cacheDir}/sync-incoming`
    removeTree(staging)
    fs.mkdirSync(staging)

    // The port is a local endpoint; the bridge between it and a remote device
    // is formed by connect() on the other side, so nothing listens here in the
    // TCP sense.
    dataTransfer.createPort(NEARLINK_SYNC_UUID)
    this.portOpen = true
    nearLinkLog(`recv port created uuid=${NEARLINK_SYNC_UUID} code=${this.code}`)
    this.session = new SyncSession(
      targetRoot,
      staging,
      this.code,
      (bytes: ArrayBuffer) => this.sendBack(bytes),
      onProgress,
      onSessions,
      (report: SyncReport, error: string) => {
        this.finished = true
        onFinished(report, error)
        void this.close()
      }
    )
    dataTransfer.on('readData', this.onRead)
    dataTransfer.on('connectionStateChanged', this.onConnState)
    this.advId = await startAdvertise()
    console.info(`NEARLINK-RECV advertising id=${this.advId} code=${this.code}`)
  }

  private async sendBack(bytes: ArrayBuffer): Promise<void> {
    if (this.peer.length === 0) {
      nearLinkLog('recv sendBack without peer')
      throw new Error('还没有星闪对端')
    }
    try {
      await dataTransfer.writeData({ address: this.peer, uuid: NEARLINK_SYNC_UUID, data: bytes })
      nearLinkLog(`recv sendBack ok bytes=${bytes.byteLength}`)
    } catch (error) {
      nearLinkLog(`recv sendBack failed bytes=${bytes.byteLength} ${JSON.stringify(error)}`)
      throw new Error((error as Error).message)
    }
  }

  async close(): Promise<void> {
    try {
      dataTransfer.off('readData', this.onRead)
    } catch (error) {
      // No listener registered.
    }
    try {
      dataTransfer.off('connectionStateChanged', this.onConnState)
    } catch (error) {
      // No listener registered.
    }
    if (this.advId >= 0) {
      try {
        await advertising.stopAdvertising(this.advId)
      } catch (error) {
        // Already stopped.
      }
      this.advId = -1
    }
    if (this.portOpen) {
      try {
        dataTransfer.destroyPort(NEARLINK_SYNC_UUID)
      } catch (error) {
        // Already gone.
      }
      this.portOpen = false
    }
    this.session = null
    this.peer = ''
  }
}

/** Ask for ACCESS_NEARLINK; forwarding keeps the UI code unaware of the API. */
export async function ensureNearLinkPermission(context: common.UIAbilityContext): Promise<boolean> {
  return requestNearLinkPermission(context)
}
