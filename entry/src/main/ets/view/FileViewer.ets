import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { fileIo as fs } from '@kit.CoreFileKit'
import { MdText } from './Markdown'
import { saveToGallery } from '../common/Gallery'
import { shareFile } from '../common/FileShare'
import {
  enableWholePageDrawing, exportPageAsPdf, exportPageAsPng, ExportOutcome, printPageAsPdf
} from '../common/PageExport'

/** How a referenced file renders. */
enum PreviewKind {
  WEB = 'web',
  IMAGE = 'image',
  MARKDOWN = 'markdown',
  TEXT = 'text'
}

const WEB_EXTS: string[] = ['html', 'htm', 'svg']
const IMAGE_EXTS: string[] = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp']
const MD_EXTS: string[] = ['md', 'markdown']
const MAX_TEXT_BYTES: number = 1048576

function extOf(path: string): string {
  const name = path.substring(path.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  if (dot <= 0) {
    return ''
  }
  return name.substring(dot + 1).toLowerCase()
}

function kindOf(path: string): PreviewKind {
  const ext = extOf(path)
  for (const item of WEB_EXTS) {
    if (item === ext) {
      return PreviewKind.WEB
    }
  }
  for (const item of IMAGE_EXTS) {
    if (item === ext) {
      return PreviewKind.IMAGE
    }
  }
  for (const item of MD_EXTS) {
    if (item === ext) {
      return PreviewKind.MARKDOWN
    }
  }
  return PreviewKind.TEXT
}

/**
 * Full-screen preview for files dsh creates or mentions in chat.
 *
 * HTML/SVG render in an embedded Web component (file:// from the app
 * sandbox), images in an Image, Markdown through the chat renderer, and
 * everything else as capped monospace text. Mounted per open through
 * bindContentCover; @Watch re-opens it if the cover component is reused
 * for a different file.
 */
@Component
export struct FileViewer {
  @Prop @Watch('onSourceChange') filePath: string = ''
  @Prop fileName: string = ''
  @State kind: PreviewKind = PreviewKind.TEXT
  @State text: string = ''
  @State truncated: boolean = false
  @State failed: string = ''
  /**
   * Top inset for the status bar.
   *
   * bindContentCover draws over the whole screen on this device, so without
   * this the header (close button, title, save button) sits *inside* the
   * status bar and taps there go to the system — which is exactly how the save
   * button appeared present but did nothing.
   */
  @State topInset: number = 0
  /** Export menu is open (Web previews only). */
  @State exportOpen: boolean = false
  @State exporting: boolean = false
  onClose: () => void = () => {}
  private controller: webview.WebviewController = new webview.WebviewController()

  aboutToAppear(): void {
    // Must happen while the Web component is being created, otherwise a
    // snapshot only ever captures the viewport.
    enableWholePageDrawing()
    this.open()
    this.measureInset()
  }

  private measureInset(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext
      window.getLastWindow(context).then((win: window.Window) => {
        const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
        this.topInset = px2vp(area.topRect.height)
      }).catch(() => {
        this.topInset = 0
      })
    } catch (error) {
      this.topInset = 0
    }
  }

  onSourceChange(): void {
    this.open()
  }

  private open(): void {
    this.failed = ''
    this.text = ''
    this.truncated = false
    try {
      if (this.filePath.length === 0) {
        this.failed = '没有可打开的文件路径。'
        return
      }
      if (!fs.accessSync(this.filePath)) {
        // Name the actual path: the usual cause is an external directory whose
        // grant lapsed, not a deleted file, and the user cannot tell those
        // apart from a vague message.
        this.failed = `找不到该文件：${this.filePath}\n外部目录的访问授权可能已失效，重新绑定项目目录后可恢复。`
        return
      }
      this.kind = kindOf(this.filePath)
      if (this.kind === PreviewKind.TEXT || this.kind === PreviewKind.MARKDOWN) {
        const size = fs.statSync(this.filePath).size
        this.truncated = size > MAX_TEXT_BYTES
        this.text = fs.readTextSync(this.filePath, { length: MAX_TEXT_BYTES })
      }
    } catch (error) {
      this.failed = `无法读取文件：${(error as Error).message}`
    }
  }

  private fileUrl(): string {
    return `file://${this.filePath}`
  }

  /** Write the open image into the gallery inside the SaveButton's grant. */
  private async saveImage(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    const message = await saveToGallery(context, this.filePath)
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 })
  }

  /** Send the open file to another app; the panel is the only feedback. */
  private async shareOpen(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    const message = await shareFile(context, this.filePath)
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 })
  }

  /**
   * Render the whole HTML page into a file and hand it to the share panel.
   *
   * The share panel is the point of the export: a long image or a PDF that
   * stays inside the app would be a screenshot nobody can send.
   */
  private async exportPage(asPdf: boolean): Promise<void> {
    if (this.exporting) {
      return
    }
    this.exporting = true
    this.exportOpen = false
    const context = getContext(this) as common.UIAbilityContext
    try {
      const outcome: ExportOutcome = asPdf
        ? await exportPageAsPdf(context, this.controller, this.fileName)
        : await exportPageAsPng(context, this.controller, this.fileName)
      if (!outcome.ok) {
        this.getUIContext().getPromptAction().showToast({ message: outcome.message, duration: 2600 })
        return
      }
      const message = await shareFile(context, outcome.path)
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2400 })
    } finally {
      this.exporting = false
    }
  }

  /** Two rows, because "image or PDF" is the only choice a page has. */
  @Builder
  exportMenu() {
    Column({ space: 2 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.picture'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')])
        Column({ space: 1 }) {
          Text('导出为长图 PNG').fontSize(14).fontColor($r('app.color.text_primary'))
          Text('整页一张图，适合发社交软件').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width(200)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        void this.exportPage(false)
      })

      Divider().color($r('app.color.divider')).margin({ left: 12, right: 12 })

      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')])
        Column({ space: 1 }) {
          Text('导出为 PDF').fontSize(14).fontColor($r('app.color.text_primary'))
          Text('单页长文档，适合打印或存档').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width(200)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        void this.exportPage(true)
      })
    }
    .padding({ top: 4, bottom: 4 })
  }

  /**
   * Serve the page's own 打印 button.
   *
   * Generated pages wire it to `window.print()`, which an embedded Web
   * component ignores: the host owns printing. The page is printed as the
   * same one-page PDF the export produces, so paper matches the screen.
   */
  private async printHostPage(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    const message = await printPageAsPdf(context, this.controller, this.fileName)
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2400 })
  }

  /** Replace window.print once the page script is in place. */
  private hookPagePrint(): void {
    try {
      this.controller.runJavaScript(
        'window.print = function () { try { window.dshHost.printPage(); console.log("DSH-PRINT bridge-ok"); } ' +
        'catch (error) { console.log("DSH-PRINT bridge-missing " + error); } };' +
        'console.log("DSH-PRINT hooked host=" + (typeof window.dshHost));'
      )
    } catch (error) {
      // A page without a print button simply never calls it.
    }
  }

  build() {
    Column() {
      Row() {
        Button('关闭')
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onClose())

        Text(this.fileName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .margin({ left: 12 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12, right: 12 })

        // A long HTML page cannot be sent as a page, so export comes first and
        // puts a single file (long image or PDF) in front of the share panel.
        if (this.kind === PreviewKind.WEB && this.failed.length === 0) {
          Button(this.exporting ? '导出中…' : '导出')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.exporting)
            .margin({ right: 8 })
            .bindPopup(this.exportOpen, {
              builder: (): void => {
                this.exportMenu()
              },
              placement: Placement.Bottom,
              popupColor: $r('app.color.surface'),
              enableArrow: true,
              autoCancel: true,
              onStateChange: (state: PopupStateChangeParam) => {
                if (!state.isVisible) {
                  this.exportOpen = false
                }
              }
            })
            .onClick(() => {
              this.exportOpen = !this.exportOpen
            })
        }

        // Share sits beside the type-specific action rather than behind a menu:
        // opening a file is already deliberate, so sending it is one tap away.
        if (this.failed.length === 0) {
          Button('分享')
            .fontSize(13)
            .height(32)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .margin({ right: 8 })
            .onClick(() => {
              void this.shareOpen()
            })
        }

        if (this.kind === PreviewKind.IMAGE && this.failed.length === 0) {
          // Security component: the tap itself grants the temporary media
          // write permission, which is why the shell needs no ACL for this.
          SaveButton({
            icon: SaveIconStyle.FULL_FILLED,
            text: SaveDescription.SAVE_IMAGE,
            buttonType: ButtonType.Capsule
          })
            .fontSize(13)
            .height(32)
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result !== SaveButtonOnClickResult.SUCCESS) {
                this.getUIContext().getPromptAction().showToast({
                  message: '未获得保存授权',
                  duration: 1800
                })
                return
              }
              void this.saveImage()
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10 + this.topInset, bottom: 10 })

      Divider().color($r('app.color.divider'))

      if (this.failed.length > 0) {
        Column({ space: 8 }) {
          Text(this.failed)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Text(this.filePath)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_tertiary'))
            .copyOption(CopyOptions.LocalDevice)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 32, right: 32 })
      } else if (this.kind === PreviewKind.WEB) {
        Web({ src: this.fileUrl(), controller: this.controller })
          .fileAccess(true)
          .domStorageAccess(true)
          // The bridge lets the page's own buttons reach the host; only
          // printing is exposed, and only as "print this page".
          .javaScriptProxy({
            object: {
              printPage: (): void => {
                void this.printHostPage()
              }
            },
            name: 'dshHost',
            methodList: ['printPage'],
            controller: this.controller
          })
          .onPageEnd(() => {
            this.hookPagePrint()
          })
          .onConsole((event) => {
            // Visible in `devecocli log`: the page's own diagnostics, plus the
            // markers that say whether the print bridge exists.
            console.info(`DSH-WEB ${event.message.getMessage()}`)
            return false
          })
          .layoutWeight(1)
          .width('100%')
      } else if (this.kind === PreviewKind.IMAGE) {
        Scroll() {
          Image(this.fileUrl())
            .objectFit(ImageFit.Contain)
            .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      } else if (this.kind === PreviewKind.MARKDOWN) {
        Scroll() {
          Column({ space: 6 }) {
            if (this.truncated) {
              Text('文件超过 1MB，仅显示开头部分。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            MdText({ raw: this.text })
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ minHeight: '100%' })
          .width('100%')
          .padding(12)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      } else {
        Scroll() {
          Column({ space: 6 }) {
            if (this.truncated) {
              Text('文件超过 1MB，仅显示开头部分。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            Text(this.text)
              .fontSize(13)
              .fontFamily('monospace')
              .lineHeight(19)
              .fontColor($r('app.color.text_primary'))
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .constraintSize({ minHeight: '100%' })
          .width('100%')
          .padding(12)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'))
  }
}
