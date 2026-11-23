import { constant, remoteDevice } from '@kit.NearLinkKit'
import { abilityDelegatorRegistry } from '@kit.TestKit'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { describe, expect, it } from '@ohos/hypium'
import {
  NearLinkPeer, NearLinkSyncLink, NearLinkSyncReceiver, nearLinkSyncSupported, scanNearLinkPeers,
  setNearLinkLog
} from '../../../main/ets/common/NearLinkSync'
import {
  collectEntries, removeTree, sendProjectOver, SyncEntry, SyncProgress, SyncReport
} from '../../../main/ets/common/ProjectSync'

/**
 * Project sync over 星闪, between two devices, driven from the test harness.
 *
 * The radio needs two devices at once, so this cannot be a normal test: the
 * role is passed on the command line and each device runs the half it can.
 *
 *   # device A (receiver), background:
 *   hdc -t <serial> shell "aa test -b com.qtepp.harmonygo -m entry_test \
 *     -s unittest OpenHarmonyTestRunner -s timeout 120000 -s role receiver"
 *   # device B (sender), after A prints its code — scan first to learn the peer:
 *   hdc -t <serial> shell "aa test ... -s role scan"
 *   hdc -t <serial> shell "aa test ... -s role sender -s peer 11:22:33:AA:BB:FF"
 *
 * Without `role` the test asserts nothing and passes, so the ordinary suite
 * (`bash scripts/test.sh device`) stays green on a single device.
 */
const SYNC_CODE = '246810'
const PEER_PARAM = 'peer'
const PEER_NAME_PARAM = 'peerName'
const ROLE_PARAM = 'role'

interface TestParams {
  role: string
  peer: string
  peerName: string
}

/**
 * Read `-s role …` / `-s peer …` from `aa test`.
 *
 * The delegator keeps the raw switch in the key (`-s role`), not the bare word
 * — discovered by logging the key list — so both spellings are accepted to keep
 * the test usable if a future runner normalises them.
 */
function paramValue(raw: Record<string, string>, name: string): string {
  const switched = raw[`-s ${name}`]
  if (switched !== undefined && switched.length > 0) {
    return switched
  }
  const plain = raw[name]
  return plain === undefined ? '' : plain
}

function params(): TestParams {
  const raw = abilityDelegatorRegistry.getArguments().parameters
  return {
    role: paramValue(raw, ROLE_PARAM),
    peer: paramValue(raw, PEER_PARAM),
    peerName: paramValue(raw, PEER_NAME_PARAM)
  }
}

function appContext(): common.UIAbilityContext {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as common.UIAbilityContext
}

function writeText(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  try {
    fs.writeSync(file.fd, text)
  } finally {
    fs.closeSync(file)
  }
}

function writeZeros(path: string, length: number): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  try {
    fs.writeSync(file.fd, new ArrayBuffer(length))
  } finally {
    fs.closeSync(file)
  }
}

function wait(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms))
}

/**
 * Append a line to a file the harness can pull with `hdc file recv`.
 *
 * hilog from the test process is not reliably readable on both devices (the
 * tablet's buffer showed nothing for our tag), and a silent receiver is exactly
 * the thing this test has to distinguish from a refused connect, so the facts
 * are written where reading them is a file copy rather than a log hunt.
 */
function diag(path: string, line: string): void {
  try {
    const dir = path.substring(0, path.lastIndexOf('/'))
    if (dir.length > 0 && !fs.accessSync(dir)) {
      fs.mkdirSync(dir, true)
    }
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.WRITE_ONLY)
    try {
      const stamp = `${new Date().toISOString()} ${line}\n`
      fs.writeSync(file.fd, stamp)
    } finally {
      fs.closeSync(file)
    }
  } catch (error) {
    // Diagnostics must never fail the test itself.
  }
}

export default function nearLinkSyncTest() {
  describe('NearLinkSync', () => {
    const context = appContext()
    const root = `${context.filesDir}/nl-sync-test`
    // cacheDir is created by the system before the test runs; filesDir is not
    // guaranteed for the test module. Write to both and keep whichever accepts.
    const diagPaths: string[] = [`${context.cacheDir}/nl-diag.log`, `${context.filesDir}/nl-diag.log`]
    const diagPath = diagPaths[0]
    setNearLinkLog((line: string) => {
      for (const path of diagPaths) {
        diag(path, line)
      }
    })
    diag(diagPath, `diag start role=${params().role} cacheDir=${context.cacheDir}`)

    it('carries a file across the 星闪 link', 0, async () => {
      const options = params()
      const rawArgs = abilityDelegatorRegistry.getArguments()
      console.info(`NEARLINK-CONFIG role=[${options.role}] peer=[${options.peer}] keys=[${Object.keys(rawArgs.parameters).join(',')}]`)
      if (options.role.length === 0 || !nearLinkSyncSupported()) {
        expect(true).assertTrue()
        return
      }
      removeTree(root)
      fs.mkdirSync(`${root}/src`, true)
      fs.mkdirSync(`${root}/dst`, true)
      writeText(`${root}/src/note.txt`, 'across the radio\n')
      // Bigger than one packet by two orders of magnitude, so the chunking path
      // (and the negotiated payload cap) is exercised too.
      writeZeros(`${root}/src/big.bin`, 40000)
      // Enough entries that the manifest itself exceeds one 星闪 packet: the
      // control frames have to be split or the hello write is refused.
      const many = `${root}/src/many`
      fs.mkdirSync(many, true)
      for (let index = 0; index < 120; index++) {
        writeText(`${many}/file-${index}.txt`, `row ${index}\n`)
      }

      if (options.role === 'scan') {
        const peers: NearLinkPeer[] = await scanNearLinkPeers(6000)
        diag(diagPath, `scan found ${peers.length}`)
        for (const peer of peers) {
          console.info(`NEARLINK-PEER ${peer.address} name=${peer.name} rssi=${peer.rssi}`)
        }
        expect(true).assertTrue()
        return
      }

      if (options.role === 'receiver') {
        const receiver = new NearLinkSyncReceiver()
        let settle: (report: SyncReport | null) => void = (_report: SyncReport | null) => {}
        const finished = new Promise<SyncReport | null>((resolve) => {
          settle = (report: SyncReport | null): void => resolve(report)
        })
        const timer = setTimeout(() => settle(null), 150000)
        diag(diagPath, 'receiver open start')
        try {
          await receiver.open(
            context,
            `${root}/dst`,
            SYNC_CODE,
            (_progress: SyncProgress) => {},
            (_json: string) => {},
            (report: SyncReport, error: string) => {
              clearTimeout(timer)
              diag(diagPath, `receiver finished files=${report.files} error=[${error}]`)
              settle(error.length === 0 ? report : null)
            }
          )
          diag(diagPath, 'receiver advertising ok')
        } catch (error) {
          diag(diagPath, `receiver open failed ${JSON.stringify(error)}`)
          settle(null)
        }
        const report = await finished
        await receiver.close()
        expect(report === null ? -1 : (report as SyncReport).files).assertEqual(122)
        expect(fs.statSync(`${root}/dst/note.txt`).size).assertEqual(17)
        expect(fs.statSync(`${root}/dst/big.bin`).size).assertEqual(40000)
        removeTree(root)
        return
      }

      // Sender. The peer address is discovered in this same run: SLE addresses
      // rotate, so an address remembered from an earlier scan can point at
      // nothing (connect then fails with 1009700099 and the service logs an
      // invalid address). `-s peerName <substring>` picks the target by name.
      let peer = options.peer
      if (peer.length === 0) {
        const peers: NearLinkPeer[] = await scanNearLinkPeers(8000)
        for (const found of peers) {
          console.info(`NEARLINK-PEER ${found.address} name=${found.name} rssi=${found.rssi}`)
        }
        for (const found of peers) {
          if (options.peerName.length > 0 && found.name.indexOf(options.peerName) < 0) {
            continue
          }
          peer = found.address
          break
        }
        if (peer.length === 0 && options.peerName.length > 0) {
          const fallback = await scanNearLinkPeers(6000)
          for (const found of fallback) {
            console.info(`NEARLINK-PEER2 ${found.address} name=${found.name}`)
            if (found.name.indexOf(options.peerName) >= 0) {
              peer = found.address
              break
            }
          }
        }
      }
      if (peer.length === 0) {
        console.error('NEARLINK-E2E no peer found')
        expect(false).assertTrue()
        return
      }
      // Pairing first: a bare connect to an unpaired peer fails with
      // "Operation failed." and the service logs an invalid address, because
      // the scanned address is a resolvable/encrypted form. Pairing turns it
      // into a connection we are allowed to make (both screens confirm).
      const remote = remoteDevice.createRemoteDevice(peer)
      diag(diagPath, `peer=${peer} pairing=${remote.getPairingState()}`)
      if (remote.getPairingState() !== constant.PairingState.PAIRING_STATE_PAIRED) {
        try {
          await remote.startPairing()
        } catch (error) {
          console.error(`NEARLINK-PAIR start failed: ${(error as Error).message}`)
        }
        for (let i = 0; i < 120; i++) {
          if (remote.getPairingState() === constant.PairingState.PAIRING_STATE_PAIRED) {
            break
          }
          await wait(500)
        }
        console.info(`NEARLINK-PAIR state-after=${remote.getPairingState()}`)
      }
      // Which packet size the handshake accepts is unknown; probe the small
      // one first, because a refusal at 65535 would otherwise look like a
      // dead link. Both outcomes are logged with their error codes.
      // The receiver needs a moment after `aa test` starts before it is
      // advertising, so retry instead of measuring from launch: a first
      // attempt that lands too early reports the same 1009700099 as a real
      // failure and would send the diagnosis in the wrong direction.
      // Use the same path the app uses (default packet size, internal fallback),
      // retrying while the receiver finishes starting up.
      let link: NearLinkSyncLink | null = null
      for (let attempt = 0; attempt < 15 && link === null; attempt++) {
        const candidate = new NearLinkSyncLink(peer)
        try {
          await candidate.connect()
          diag(diagPath, `connect attempt=${attempt} ok`)
          link = candidate
          break
        } catch (error) {
          diag(diagPath, `connect attempt=${attempt} failed ${JSON.stringify(error)}`)
          await candidate.close()
          await wait(2000)
        }
      }
      if (link === null) {
        expect(false).assertTrue()
        return
      }
      const entries: SyncEntry[] = collectEntries(`${root}/src`, [], [])
      let sent: SyncReport | null = null
      const active = link as NearLinkSyncLink
      try {
        sent = await sendProjectOver(
          active, `${root}/src`, entries, SYNC_CODE, 'test-device', '',
          (_progress: SyncProgress) => {}, () => false
        )
      } finally {
        await active.close()
      }
      await wait(500)
      diag(diagPath, `sent files=${sent === null ? -1 : (sent as SyncReport).files}`)
      expect(sent === null ? -1 : (sent as SyncReport).files).assertEqual(122)
      removeTree(root)
    })
  })
}
