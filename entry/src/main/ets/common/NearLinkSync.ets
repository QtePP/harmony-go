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
  return await advertising.startAdvertising(params)
}

/**
 * Sender side: connect to one peer and turn `writeData/readData` into a link.
 */
export class NearLinkSyncLink implements SyncLink {
  private address: string
  private bytesHandler: ((bytes: ArrayBuffer) => void) | null = null
  private closedHandler: (() => void) | null = null
  private connected: boolean = false
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
    if (state === constant.ConnectionState.STATE_DISCONNECTED && this.closedHandler !== null) {
      this.closedHandler()
    }
  }

  constructor(address: string) {
    this.address = address
  }

  /** Establish the port channel; pairing may show a system dialog. */
  async connect(): Promise<void> {
    dataTransfer.on('readData', this.onRead)
    dataTransfer.on('connectionStateChanged', this.onState)
    await dataTransfer.connect({ address: this.address, uuid: NEARLINK_SYNC_UUID, mtu: NEARLINK_MTU })
    this.connected = true
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
    await dataTransfer.writeData({ address: this.address, uuid: NEARLINK_SYNC_UUID, data: bytes })
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
    if (this.session === null) {
      return
    }
    this.peer = params.address
    void this.session.push(params.data)
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
    this.advId = await startAdvertise()
  }

  private async sendBack(bytes: ArrayBuffer): Promise<void> {
    if (this.peer.length === 0) {
      throw new Error('还没有星闪对端')
    }
    await dataTransfer.writeData({ address: this.peer, uuid: NEARLINK_SYNC_UUID, data: bytes })
  }

  async close(): Promise<void> {
    try {
      dataTransfer.off('readData', this.onRead)
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
