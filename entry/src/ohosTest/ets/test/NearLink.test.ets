import { abilityDelegatorRegistry } from '@kit.TestKit'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { describe, expect, it } from '@ohos/hypium'
import {
  NearLinkPeer, NearLinkSyncLink, NearLinkSyncReceiver, nearLinkSyncSupported, scanNearLinkPeers
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
const ROLE_PARAM = 'role'

interface TestParams {
  role: string
  peer: string
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
  return { role: paramValue(raw, ROLE_PARAM), peer: paramValue(raw, PEER_PARAM) }
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

function wait(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms))
}

export default function nearLinkSyncTest() {
  describe('NearLinkSync', () => {
    const context = appContext()
    const root = `${context.filesDir}/nl-sync-test`

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

      if (options.role === 'scan') {
        const peers: NearLinkPeer[] = await scanNearLinkPeers(6000)
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
        const timer = setTimeout(() => settle(null), 90000)
        await receiver.open(
          context,
          `${root}/dst`,
          SYNC_CODE,
          (_progress: SyncProgress) => {},
          (_json: string) => {},
          (report: SyncReport, error: string) => {
            clearTimeout(timer)
            settle(error.length === 0 ? report : null)
          }
        )
        const report = await finished
        await receiver.close()
        expect(report === null ? -1 : (report as SyncReport).files).assertEqual(1)
        expect(fs.statSync(`${root}/dst/note.txt`).size).assertEqual(18)
        removeTree(root)
        return
      }

      // Sender. Scanning in the same run keeps it to one command when the peer
      // is the only 星闪 device nearby; otherwise pass -s peer <address>.
      let peer = options.peer
      if (peer.length === 0) {
        const peers: NearLinkPeer[] = await scanNearLinkPeers(6000)
        for (const found of peers) {
          console.info(`NEARLINK-PEER ${found.address} name=${found.name} rssi=${found.rssi}`)
          if (peer.length === 0) {
            peer = found.address
          }
        }
      }
      if (peer.length === 0) {
        console.error('NEARLINK-E2E no peer found')
        expect(false).assertTrue()
        return
      }
      const link = new NearLinkSyncLink(peer)
      await link.connect()
      const entries: SyncEntry[] = collectEntries(`${root}/src`, [], [])
      let sent: SyncReport | null = null
      try {
        sent = await sendProjectOver(
          link, `${root}/src`, entries, SYNC_CODE, 'test-device', '',
          (_progress: SyncProgress) => {}, () => false
        )
      } finally {
        await link.close()
      }
      await wait(500)
      console.info(`NEARLINK-E2E sent ${sent === null ? -1 : (sent as SyncReport).files} files`)
      expect(sent === null ? -1 : (sent as SyncReport).files).assertEqual(1)
      removeTree(root)
    })
  })
}
