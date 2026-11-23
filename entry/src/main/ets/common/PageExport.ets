import { webview } from '@kit.ArkWeb'
import { BusinessError } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { image } from '@kit.ImageKit'
import { print } from '@kit.BasicServicesKit'

/**
 * Turn a rendered Web page into a shareable file.
 *
 * A generated HTML artifact is usually taller than the screen, so "share the
 * page" means far more than a viewport screenshot: the whole page has to be
 * drawn once and packed into a single image, or into a one-page PDF whose page
 * height is the page's height. `webPageSnapshot` gives exactly that, but only
 * after `enableWholeWebPageDrawing()` was called while the Web component was
 * being created — a viewport snapshot is what you get otherwise, silently.
 *
 * Both formats are written into the app cache under `exports/`, because the
 * share panel needs a real file it can read after this view is gone.
 */

/** Where an exported file went, or why it did not. */
export interface ExportOutcome {
  ok: boolean
  path: string
  message: string
}

const EXPORT_DIR: string = 'exports'

/** Call before a Web component is created; without it snapshots are viewport-only. */
export function enableWholePageDrawing(): void {
  try {
    webview.WebviewController.enableWholeWebPageDrawing()
  } catch (error) {
    // Older devices simply do not offer it; the viewer keeps working.
  }
}

function exportDir(context: common.UIAbilityContext): string {
  const dir = `${context.cacheDir}/${EXPORT_DIR}`
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true)
  }
  return dir
}

function baseNameOf(fileName: string): string {
  const dot = fileName.lastIndexOf('.')
  const base = dot > 0 ? fileName.substring(0, dot) : fileName
  const safe = base.replace(/[\\/:*?"<>|]/g, '_')
  return safe.length > 0 ? safe : 'page'
}

function writeBytes(path: string, bytes: ArrayBuffer): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  try {
    fs.writeSync(file.fd, bytes)
  } finally {
    fs.closeSync(file)
  }
}

function asciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length)
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff
  }
  return out
}

/** Snapshot the whole page; null when the platform refuses or has nothing to draw. */
async function snapshotPage(controller: webview.WebviewController): Promise<image.PixelMap | null> {
  try {
    const result = await new Promise<webview.SnapshotResult | null>((resolve) => {
      controller.webPageSnapshot({ id: 'dsh-export' }, (error: BusinessError, value: webview.SnapshotResult) => {
        if (error !== null && error !== undefined) {
          resolve(null)
          return
        }
        resolve(value)
      })
    })
    if (result === null || result === undefined || result.status === false) {
      return null
    }
    const pixelMap = result.imagePixelMap
    return pixelMap === undefined ? null : pixelMap
  } catch (error) {
    return null
  }
}

/** Pack a whole-page screenshot into a PNG next to the app's cache. */
export async function exportPageAsPng(
  context: common.UIAbilityContext,
  controller: webview.WebviewController,
  fileName: string
): Promise<ExportOutcome> {
  const pixelMap = await snapshotPage(controller)
  if (pixelMap === null) {
    return { ok: false, path: '', message: '导出失败：页面还没画完，稍后再试' }
  }
  try {
    const packer = image.createImagePacker()
    const bytes = await packer.packing(pixelMap, { format: 'image/png', quality: 100 })
    const path = `${exportDir(context)}/${baseNameOf(fileName)}-长图.png`
    writeBytes(path, bytes)
    return { ok: true, path: path, message: '长图已生成' }
  } catch (error) {
    return { ok: false, path: '', message: `导出失败：${(error as Error).message}` }
  } finally {
    pixelMap.release()
  }
}

/**
 * Wrap one JPEG in a single-page PDF.
 *
 * The image is the whole page, so the PDF page keeps its aspect ratio instead
 * of being forced onto A4 — a long article stays one readable column rather
 * than a stack of A4 pages with white bands. No PDF library is needed for a
 * single embedded image: DCTDecode lets the JPEG bytes go in untouched.
 */
function buildImagePdf(jpeg: Uint8Array, width: number, height: number): ArrayBuffer {
  // Image pixels to PDF points: 96 dpi is the density the snapshot uses.
  const pageW = ((width * 72) / 96).toFixed(2)
  const pageH = ((height * 72) / 96).toFixed(2)
  const chunks: Uint8Array[] = []
  const offsets: number[] = [0, 0, 0, 0, 0, 0]
  let length = 0
  const push = (bytes: Uint8Array): void => {
    chunks.push(bytes)
    length += bytes.length
  }
  const pushText = (text: string): void => push(asciiBytes(text))
  const begin = (number: number): void => {
    offsets[number] = length
    pushText(`${number} 0 obj\n`)
  }

  pushText('%PDF-1.4\n')
  begin(1)
  pushText('<< /Type /Catalog /Pages 2 0 R >>\nendobj\n')
  begin(2)
  pushText('<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n')
  begin(3)
  pushText(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageW} ${pageH}] ` +
    '/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n')
  begin(4)
  pushText(`<< /Type /XObject /Subtype /Image /Width ${width} /Height ${height} ` +
    `/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`)
  push(jpeg)
  pushText('\nendstream\nendobj\n')
  const content = `q\n${pageW} 0 0 ${pageH} 0 0 cm\n/Im0 Do\nQ\n`
  begin(5)
  pushText(`<< /Length ${content.length} >>\nstream\n${content}\nendstream\nendobj\n`)

  const xref = length
  pushText('xref\n0 6\n0000000000 65535 f \n')
  for (let number = 1; number <= 5; number++) {
    pushText(`${`0000000000${offsets[number]}`.slice(-10)} 00000 n \n`)
  }
  pushText(`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`)

  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.length
  }
  return out.buffer as ArrayBuffer
}

/** Pack a whole-page screenshot into a one-page PDF. */
export async function exportPageAsPdf(
  context: common.UIAbilityContext,
  controller: webview.WebviewController,
  fileName: string
): Promise<ExportOutcome> {
  const pixelMap = await snapshotPage(controller)
  if (pixelMap === null) {
    return { ok: false, path: '', message: '导出失败：页面还没画完，稍后再试' }
  }
  try {
    const info = pixelMap.getImageInfoSync()
    const packer = image.createImagePacker()
    // PDF embeds JPEG directly, so the page does not grow a second PNG copy.
    const jpeg = new Uint8Array(await packer.packing(pixelMap, { format: 'image/jpeg', quality: 92 }))
    const pdf = buildImagePdf(jpeg, info.size.width, info.size.height)
    const path = `${exportDir(context)}/${baseNameOf(fileName)}.pdf`
    writeBytes(path, pdf)
    return { ok: true, path: path, message: 'PDF 已生成' }
  } catch (error) {
    return { ok: false, path: '', message: `导出失败：${(error as Error).message}` }
  } finally {
    pixelMap.release()
  }
}

/**
 * Generate the single-page PDF and hand it to the system print dialog.
 *
 * A generated HTML artifact usually ships its own 打印 button wired to
 * `window.print()`, which does nothing inside an embedded Web component: the
 * host has to decide what printing means. Here it means "print the page as
 * the same one-page PDF the export produces", so what comes out of a printer
 * is what the user sees.
 */
export async function printPageAsPdf(
  context: common.UIAbilityContext,
  controller: webview.WebviewController,
  fileName: string
): Promise<string> {
  const outcome = await exportPageAsPdf(context, controller, fileName)
  if (!outcome.ok) {
    return outcome.message
  }
  try {
    await print.print([outcome.path], context)
    return '已打开打印面板'
  } catch (error) {
    const code = (error as BusinessError).code
    if (code === 201) {
      return '打印服务不可用（设备上没有打印服务）'
    }
    return `无法打印：${(error as BusinessError).message}`
  }
}
