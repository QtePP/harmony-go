import { abilityDelegatorRegistry } from '@kit.TestKit'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { describe, expect, it } from '@ohos/hypium'
import {
  collectEntries, removeTree, sendProject, SyncEntry, SyncProgress, SyncReceiver,
  SyncReport
} from '../../../main/ets/common/ProjectSync'

/**
 * Project sync, on the device, over loopback.
 *
 * The sync protocol's two halves normally meet over a LAN between two phones,
 * which makes it awkward to test and easy to break: the unit tests cover
 * framing but not "receiver and sender actually agree". Pointing both at
 * 127.0.0.1 exercises the real socket path, the real staging-then-rename, and
 * the real pair-code check in one device-local test.
 *
 * The wrong-code case matters more than the happy path: it is what stands
 * between a LAN listener and a remote file write.
 */
interface SyncTestPaths {
  root: string
  source: string
  target: string
}

function testContext(): common.UIAbilityContext {
  // The delegator's app context has filesDir/cacheDir, which is all the sync
  // code touches; nothing here needs a UIAbility instance.
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as common.UIAbilityContext
}

function pathsFor(text: string): SyncTestPaths {
  const root = `${text}/sync-test`
  return { root: root, source: `${root}/src`, target: `${root}/dst` }
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

function resetDirs(paths: SyncTestPaths): void {
  removeTree(paths.root)
  fs.mkdirSync(`${paths.source}/nested`, true)
  fs.mkdirSync(paths.target, true)
  writeText(`${paths.source}/note.txt`, 'hello from the sender\n')
  writeZeros(`${paths.source}/nested/data.bin`, 4096)
}

interface ReceiverHandles {
  port: number
  /** The code the receiver generated; the sender must repeat exactly this. */
  pairCode: string
  finished: Promise<SyncReport | null>
}

/**
 * Open a receiver and hand back both the port it bound and a promise for the
 * outcome. The port matters: 4519 may be held by a listener from an earlier UI
 * session, and the receiver falls back to an ephemeral port rather than fail.
 */
async function openReceiver(
  context: common.UIAbilityContext,
  target: string,
  timeoutMs: number
): Promise<ReceiverHandles> {
  const receiver = new SyncReceiver()
  let settle: (report: SyncReport | null) => void = (_report: SyncReport | null) => {}
  const finished = new Promise<SyncReport | null>((resolve) => {
    settle = (report: SyncReport | null): void => resolve(report)
  })
  const timer = setTimeout(() => settle(null), timeoutMs)
  const port = await receiver.open(
    context,
    target,
    (_progress: SyncProgress) => {},
    (_json: string) => {},
    (report: SyncReport, error: string) => {
      clearTimeout(timer)
      settle(error.length === 0 ? report : null)
    }
  )
  return { port: port, pairCode: receiver.pairCode, finished: finished }
}

export default function projectSyncTest() {
  describe('ProjectSync', () => {
    const context = testContext()
    const paths = pathsFor(context.filesDir)

    it('moves a tree over loopback and stages before renaming', 0, async () => {
      resetDirs(paths)
      const receiver = await openReceiver(context, paths.target, 20000)
      const entries: SyncEntry[] = collectEntries(paths.source, [], [])
      const sent = await sendProject(
        paths.source, entries, '127.0.0.1', receiver.port, receiver.pairCode, 'test-device', '',
        (_progress: SyncProgress) => {}, () => false
      )
      const report = await receiver.finished
      expect(sent.files).assertEqual(2)
      expect(report === null ? -1 : (report as SyncReport).files).assertEqual(2)
      // Content, not just presence: a staging bug that renames empty files
      // would still pass a file count.
      expect(fs.statSync(`${paths.target}/note.txt`).size).assertEqual(22)
      expect(fs.statSync(`${paths.target}/nested/data.bin`).size).assertEqual(4096)
      removeTree(paths.root)
    })

    it('refuses to move anything when the pair code is wrong', 0, async () => {
      resetDirs(paths)
      const receiver = await openReceiver(context, paths.target, 15000)
      let threw = false
      try {
        const entries: SyncEntry[] = collectEntries(paths.source, [], [])
        await sendProject(
          paths.source, entries, '127.0.0.1', receiver.port, '000000', 'test-device', '',
          (_progress: SyncProgress) => {}, () => false
        )
      } catch (error) {
        threw = true
      }
      const report = await receiver.finished
      expect(threw).assertTrue()
      // A denied transfer reports an error string mentioning the code, and the
      // target stays empty.
      expect(report).assertNull()
      expect(fs.accessSync(`${paths.target}/note.txt`)).assertFalse()
      removeTree(paths.root)
    })
  })
}
