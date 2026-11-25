import { fileIo as fs } from '@kit.CoreFileKit'
import { zlib } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { resourceManager } from '@kit.LocalizationKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Materialises the bundled dsh payload into the app sandbox.
 *
 * The archive ships in `rawfile/`, which is read-only and not addressable as a
 * filesystem path, so Node cannot require() from it. We stream it out in 1 MiB
 * chunks (the archive is far larger than any safe in-memory buffer) and let
 * zlib unpack it. The archive length acts as the extraction stamp, making the
 * step idempotent across launches.
 */
export class Payload {
  private static readonly ARCHIVE = 'dsh-payload.zip'
  private static readonly CHUNK = 1024 * 1024

  /** Returns the absolute payload root, extracting only when the archive changes. */
  static async ensure(context: common.UIAbilityContext): Promise<string> {
    const root = `${context.filesDir}/payload`
    const marker = `${context.filesDir}/payload.stamp`
    const entry = `${root}/bootstrap.cjs`

    const descriptor = await context.resourceManager.getRawFd(Payload.ARCHIVE)
    const stamp = `${descriptor.length}`
    const archive = `${context.filesDir}/payload.zip`
    try {
      if (fs.accessSync(marker) && fs.accessSync(entry) && fs.readTextSync(marker) === stamp) {
        // Older builds copied the archive into the sandbox and never removed
        // it; reclaim that 229 MB on the next launch without re-extracting.
        Payload.removeArchive(archive)
        return root
      }

      Payload.copyDescriptor(descriptor, archive)

      if (fs.accessSync(root)) {
        await Payload.removeTree(root)
      }
      fs.mkdirSync(root)
      await zlib.decompressFile(archive, root)
      // Keep a failed archive for diagnosis, but a successful extraction no
      // longer needs the 229 MB sandbox copy: the rawfile is the source.
      Payload.removeArchive(archive)

      const handle = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      fs.writeSync(handle.fd, stamp)
      fs.closeSync(handle)
      return root
    } finally {
      context.resourceManager.closeRawFd(Payload.ARCHIVE)
    }
  }

  /** Stream an open rawfile descriptor to a sandbox path, one chunk at a time. */
  private static copyDescriptor(descriptor: resourceManager.RawFileDescriptor, destination: string): void {
    const out = fs.openSync(destination, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    const buffer = new ArrayBuffer(Payload.CHUNK)
    let position = 0
    try {
      while (position < descriptor.length) {
        const want = Math.min(Payload.CHUNK, descriptor.length - position)
        const read = fs.readSync(descriptor.fd, buffer, { offset: descriptor.offset + position, length: want })
        if (read <= 0) {
          break
        }
        fs.writeSync(out.fd, buffer, { length: read })
        position += read
      }
    } finally {
      fs.closeSync(out)
    }
    if (position !== descriptor.length) {
      throw new Error(`payload copy incomplete: ${position}/${descriptor.length}`)
    }
  }

  /** Drop a previous extraction so the next launch unpacks again. */
  static async reset(context: common.UIAbilityContext): Promise<void> {
    const marker = `${context.filesDir}/payload.stamp`
    const root = `${context.filesDir}/payload`
    try {
      if (fs.accessSync(marker)) {
        fs.unlinkSync(marker)
      }
      if (fs.accessSync(root)) {
        // `fs.rmdirSync(root)` crashed on this tree once ("remove_all_impl
        // recursion too deep", 2026-11-24). Delete leaves first and only
        // remove empty directories, so the native recursive walker never
        // sees 95k entries.
        await Payload.removeTree(root)
      }
    } catch (error) {
      const failure = error as BusinessError
      console.error(`payload reset failed: ${failure.message}`)
    }
    Payload.removeArchive(`${context.filesDir}/payload.zip`)
  }

  /**
   * Iterative-ish tree removal: recurse over directories (depth is small),
   * unlink files one by one, and rmdir only empty directories.
   *
   * The platform's `rmdirSync` recursive walker is what failed on the 1.4GB
   * payload tree; this path never hands it a populated directory.
   */
  private static async removeTree(path: string): Promise<void> {
    let names: string[] = []
    try {
      names = await fs.listFile(path)
    } catch (error) {
      return
    }
    for (const name of names) {
      const child = `${path}/${name}`
      try {
        const stat = await fs.stat(child)
        if (stat.isDirectory()) {
          await Payload.removeTree(child)
        } else {
          await fs.unlink(child)
        }
      } catch (error) {
        // A file can disappear mid-walk; the directory removal will retry.
      }
    }
    try {
      await fs.rmdir(path)
    } catch (error) {
      // A leftover file keeps the directory; next reset picks it up.
    }
  }

  /** Best-effort removal: a leftover archive must never fail a boot. */
  private static removeArchive(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path)
      }
    } catch (error) {
      const failure = error as BusinessError
      console.error(`payload archive cleanup failed: ${failure.message}`)
    }
  }
}
