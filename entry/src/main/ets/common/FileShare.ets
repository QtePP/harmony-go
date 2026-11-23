import { common } from '@kit.AbilityKit'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { uniformTypeDescriptor } from '@kit.ArkData'
import { systemShare } from '@kit.ShareKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Share one workspace file to another app through the system panel.
 *
 * The repo already shares *rendered messages* as PNGs (`ShareCard.ets`); this
 * shares the file itself, whatever it is — the thing dsh actually produced.
 * Two rules are inherited from that earlier work rather than rediscovered:
 *
 *   · the URI must come from `fileUri.getUriFromPath()`. A hand-built
 *     `file://<path>` string is accepted by the constructor and then rejected
 *     by `show()` with "IPC data is oversized" on this device.
 *   · a failure, a cancellation and a success all have to return a message,
 *     because the panel is the only visible feedback and the caller shows it
 *     as a toast.
 *
 * The uniform data type matters more than it looks: the panel filters target
 * apps by it, so a PNG announced as `general.file` offers no image targets and
 * a `.md` announced as text offers no editor. The platform can resolve a type
 * from the extension, and its answer is used unless it comes back empty.
 */

/** Extension of a path, lowercased; '' when there is none. */
export function extOf(path: string): string {
  const slash = path.lastIndexOf('/')
  const name = slash >= 0 ? path.substring(slash + 1) : path
  const dot = name.lastIndexOf('.')
  if (dot <= 0 || dot === name.length - 1) {
    return ''
  }
  return name.substring(dot + 1).toLowerCase()
}

/**
 * Stand-in type when the platform cannot name one.
 *
 * `general.file` is the honest fallback: every app that accepts a file accepts
 * it, which is a worse match than a precise type but never a wrong one.
 */
export function fallbackUtd(ext: string): string {
  if (ext === 'png') {
    return 'general.png'
  }
  if (ext === 'jpg' || ext === 'jpeg') {
    return 'general.jpeg'
  }
  if (ext === 'pdf') {
    return 'com.adobe.pdf'
  }
  if (ext === 'md' || ext === 'markdown') {
    return 'general.markdown'
  }
  if (ext === 'html' || ext === 'htm') {
    return 'general.html'
  }
  if (ext === 'txt') {
    return 'general.plain-text'
  }
  return 'general.file'
}

/**
 * Resolve the type the share panel should announce.
 *
 * The platform lookup is tried first because it knows hundreds of types we do
 * not; the static table only covers what this app is likely to produce. A
 * thrown or empty answer falls back rather than failing the share — a file
 * that cannot be typed is still a file the user wants to send.
 */
export function utdOf(path: string): string {
  const ext = extOf(path)
  if (ext.length > 0) {
    try {
      const resolved = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(ext, 'general.file')
      if (resolved !== undefined && resolved.length > 0) {
        return resolved
      }
    } catch (error) {
      // Query failure is not a share failure; fall through to the table.
    }
  }
  return fallbackUtd(ext)
}

/**
 * Whether a path already lives somewhere the share service can read directly.
 *
 * Sandbox paths (`filesDir`, `cacheDir`, …) are readable by the receiving app
 * through the share grant. A user-granted external directory is not: its
 * permission belongs to this app and can be revoked or expire, so a URI into
 * it can open on the other side and then fail to read.
 */
export function isInSandbox(path: string, context: common.UIAbilityContext): boolean {
  const roots: string[] = [
    context.filesDir, context.cacheDir, context.tempDir,
    context.preferencesDir, context.databaseDir
  ]
  for (const root of roots) {
    if (root !== undefined && root.length > 0 && path.startsWith(root)) {
      return true
    }
  }
  return false
}

/** Human name of the file behind a path. */
export function nameOf(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash >= 0 ? path.substring(slash + 1) : path
}

/**
 * Stage a copy the share panel can hold on to, for paths outside the sandbox.
 * @returns the staged path, or '' when the copy failed.
 */
function stageCopy(path: string, context: common.UIAbilityContext): string {
  const target = `${context.cacheDir}/share-${util.generateRandomUUID(true)}-${nameOf(path)}`
  try {
    const source = fs.openSync(path, fs.OpenMode.READ_ONLY)
    try {
      const destination = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      try {
        fs.copyFileSync(source.fd, destination.fd)
      } finally {
        fs.closeSync(destination)
      }
    } finally {
      fs.closeSync(source)
    }
    return target
  } catch (error) {
    return ''
  }
}

/** Drop a staged copy after the panel closes; best effort and silent. */
function dropStaged(path: string): void {
  if (path.length === 0) {
    return
  }
  try {
    fs.unlinkSync(path)
  } catch (error) {
    // The cache directory is the OS's to reclaim; a failed unlink is not news.
  }
}

/**
 * Open the system share panel for one file.
 *
 * @param context - the ability context that owns the sandbox.
 * @param path - absolute path of the file to send.
 * @returns a message for the caller's toast, in every outcome.
 */
export async function shareFile(context: common.UIAbilityContext, path: string): Promise<string> {
  if (path.length === 0) {
    return '没有可分享的文件'
  }
  try {
    if (!fs.accessSync(path)) {
      return `找不到该文件：${nameOf(path)}`
    }
  } catch (error) {
    return `无法访问该文件：${nameOf(path)}`
  }

  let readable = path
  let staged = ''
  if (!isInSandbox(path, context)) {
    // Outside the sandbox: give the panel its own copy so a lapsed grant
    // cannot turn "shared successfully" into "the other app cannot open it".
    staged = stageCopy(path, context)
    if (staged.length === 0) {
      return `无法准备分享副本：${nameOf(path)}`
    }
    readable = staged
  }

  const name = nameOf(path)
  const record: systemShare.SharedRecord = {
    utd: utdOf(readable),
    uri: '',
    title: name
  }
  try {
    record.uri = fileUri.getUriFromPath(readable)
  } catch (error) {
    dropStaged(staged)
    return `生成分享链接失败：${(error as BusinessError).message}`
  }

  // Try the detailed preview first (it shows the file), then the plain one:
  // the panel has refused modes before on this device, and the fallback costs
  // nothing when the first attempt works.
  const modes: systemShare.SharePreviewMode[] = [
    systemShare.SharePreviewMode.DETAIL,
    systemShare.SharePreviewMode.DEFAULT
  ]
  let lastError = ''
  for (const mode of modes) {
    try {
      const controller = new systemShare.ShareController(new systemShare.SharedData(record))
      await controller.show(context, {
        previewMode: mode,
        selectionMode: systemShare.SelectionMode.SINGLE
      })
      dropStaged(staged)
      return `已打开分享面板：${name}`
    } catch (error) {
      lastError = (error as BusinessError).message
    }
  }
  dropStaged(staged)
  return `分享失败：${lastError.length > 0 ? lastError : '系统面板未响应'}`
}