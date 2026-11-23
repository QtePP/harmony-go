import { common } from '@kit.AbilityKit'
import { zlib } from '@kit.BasicServicesKit'
import { window } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { fileIo as fs } from '@kit.CoreFileKit'
import { MdText } from './Markdown'
import { saveToGallery } from '../common/Gallery'
import { shareFile } from '../common/FileShare'
import { enableWholePageDrawing, exportPageAsPdf, exportPageAsPng, exportPageAsPngPair, ExportOutcome } from '../common/PageExport'
import {
  columnName,
  DocBlock,
  DocBlockKind,
  DocRun,
  isNumericText,
  parseDateStyles,
  parseDocxBlocks,
  parseSharedStrings,
  parseSheetRefs,
  parseWorksheet,
  previewLimits,
  SheetData
} from '../common/OfficePreview'

/** How a referenced file renders. */
enum PreviewKind {
  WEB = 'web',
  IMAGE = 'image',
  MARKDOWN = 'markdown',
  TEXT = 'text',
  /** .docx / .xlsx: parsed natively, rendered as a document or a grid. */
  OFFICE = 'office',
  /** A binary we cannot show; explain instead of dumping bytes as text. */
  UNSUPPORTED = 'unsupported'
}

const WEB_EXTS: string[] = ['html', 'htm', 'svg']
const IMAGE_EXTS: string[] = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp']
const MD_EXTS: string[] = ['md', 'markdown']
const DOCX_EXTS: string[] = ['docx']
const XLSX_EXTS: string[] = ['xlsx']
const UNSUPPORTED_EXTS: string[] = ['doc', 'xls', 'ppt', 'pptx']
const MAX_TEXT_BYTES: number = 1048576
/** Larger packages are refused before unzip; a phone has no swap. */
const MAX_OFFICE_BYTES: number = 20 * 1024 * 1024
const MAX_DOCX_BLOCKS: number = 400

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
  for (const item of DOCX_EXTS) {
    if (item === ext) {
      return PreviewKind.OFFICE
    }
  }
  for (const item of XLSX_EXTS) {
    if (item === ext) {
      return PreviewKind.OFFICE
    }
  }
  for (const item of UNSUPPORTED_EXTS) {
    if (item === ext) {
      return PreviewKind.UNSUPPORTED
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
  /** Accent for Office headings, bullets and the active sheet tab. */
  @StorageLink('accent') accent: string = '#4D6BFE'
  /** Office preview state: parsed lazily, because unzipping on open is async. */
  @State officeLoading: boolean = false
  @State officeError: string = ''
  @State officeKind: string = ''
  @State docBlocks: DocBlock[] = []
  @State sheets: SheetData[] = []
  @State activeSheet: number = 0
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
    this.officeError = ''
    this.officeLoading = false
    this.officeKind = ''
    this.docBlocks = []
    this.sheets = []
    this.activeSheet = 0
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
      if (this.kind === PreviewKind.UNSUPPORTED) {
        this.failed = `暂不支持直接预览 ${extOf(this.filePath).toUpperCase()} 文件。\n可以点右上角「分享」，用系统里的 Office/WPS 打开。`
        return
      }
      if (this.kind === PreviewKind.OFFICE) {
        this.officeLoading = true
        void this.openOffice()
        return
      }
      if (this.kind === PreviewKind.TEXT || this.kind === PreviewKind.MARKDOWN) {
        const size = fs.statSync(this.filePath).size
        this.truncated = size > MAX_TEXT_BYTES
        this.text = fs.readTextSync(this.filePath, { length: MAX_TEXT_BYTES })
      }
    } catch (error) {
      this.failed = `无法读取文件：${(error as Error).message}`
    }
  }

  /**
   * Unzip the package with the system zlib and parse the OOXML in ArkTS.
   *
   * The unzip is the only platform call: `@ohos.zlib` is a system capability,
   * so this works under the same no-JIT/no-WASM constraints as the rest of the
   * app. The extracted XML is small (text and styles, not images) and lives in
   * cacheDir, which is safe for the system to purge.
   */
  private async openOffice(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext
      const size = fs.statSync(this.filePath).size
      if (size > MAX_OFFICE_BYTES) {
        throw new Error(`文件超过 20MB（${Math.round(size / 1024 / 1024)}MB），请分享到其他应用打开`)
      }
      const dir = `${context.cacheDir}/office-preview`
      if (fs.accessSync(dir)) {
        fs.rmdirSync(dir)
      }
      fs.mkdirSync(dir)
      await zlib.decompressFile(this.filePath, dir)
      const ext = extOf(this.filePath)
      if (ext === 'docx') {
        const xmlPath = `${dir}/word/document.xml`
        if (!fs.accessSync(xmlPath)) {
          throw new Error('这个 .docx 里没有 word/document.xml')
        }
        const xml = fs.readTextSync(xmlPath)
        const blocks = parseDocxBlocks(xml)
        this.docBlocks = blocks.length > MAX_DOCX_BLOCKS ? blocks.slice(0, MAX_DOCX_BLOCKS) : blocks
        this.officeKind = 'docx'
        return
      }
      const workbookPath = `${dir}/xl/workbook.xml`
      if (!fs.accessSync(workbookPath)) {
        throw new Error('这个 .xlsx 里没有 xl/workbook.xml')
      }
      const workbook = fs.readTextSync(workbookPath)
      const relsPath = `${dir}/xl/_rels/workbook.xml.rels`
      const rels = fs.accessSync(relsPath) ? fs.readTextSync(relsPath) : ''
      const sharedPath = `${dir}/xl/sharedStrings.xml`
      const shared = fs.accessSync(sharedPath) ? parseSharedStrings(fs.readTextSync(sharedPath)) : []
      const stylesPath = `${dir}/xl/styles.xml`
      const dates = fs.accessSync(stylesPath) ? parseDateStyles(fs.readTextSync(stylesPath)) : []
      const refs = parseSheetRefs(workbook, rels)
      const sheets: SheetData[] = []
      for (const ref of refs) {
        if (ref.target.indexOf('..') >= 0) {
          continue
        }
        const sheetPath = `${dir}/${ref.target}`
        if (!fs.accessSync(sheetPath)) {
          continue
        }
        const rows = parseWorksheet(fs.readTextSync(sheetPath), shared, dates)
        const limits = previewLimits()
        let truncated = rows.length >= limits[0]
        for (const row of rows) {
          if (row.length >= limits[1]) {
            truncated = true
          }
        }
        sheets.push(new SheetData(ref.name, rows, truncated))
      }
      if (sheets.length === 0) {
        throw new Error('没有可预览的工作表')
      }
      this.sheets = sheets
      this.activeSheet = 0
      this.officeKind = 'xlsx'
    } catch (error) {
      this.officeError = `无法预览该文档：${(error as Error).message}`
    } finally {
      this.officeLoading = false
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

  /**
   * Export the page in both themes.
   *
   * A kit page is supposed to work light and dark; checking that by eye means
   * two files, not a claim. No share panel here — two files at once is not
   * something the sheet takes, so the toast names them and the files panel
   * can send either.
   */
  private async exportPagePair(): Promise<void> {
    if (this.exporting) {
      return
    }
    this.exporting = true
    this.exportOpen = false
    const context = getContext(this) as common.UIAbilityContext
    try {
      const outcome: ExportOutcome = await exportPageAsPngPair(context, this.controller, this.fileName)
      this.getUIContext().getPromptAction().showToast({ message: outcome.message, duration: 3200 })
    } finally {
      this.exporting = false
    }
  }

  /** Theme comparison row, then the two export formats. */
  @Builder
  exportMenu() {
    Column({ space: 2 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.picture'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')])
        Column({ space: 1 }) {
          Text('导出长图（亮 + 暗）').fontSize(14).fontColor($r('app.color.text_primary'))
          Text('同一页各出一张，检查两套主题').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width(220)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        void this.exportPagePair()
      })

      Divider().color($r('app.color.divider')).margin({ left: 12, right: 12 })

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

  /** Office body: loading, an honest error, a Word page, or an Excel grid. */
  @Builder
  officeView() {
    if (this.officeLoading) {
      Column({ space: 10 }) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(this.accent)
        Text('正在解析文档…')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.officeError.length > 0) {
      Column({ space: 8 }) {
        Text(this.officeError)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        Text('可以点右上角「分享」，用系统里的 Office / WPS 打开。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
    } else if (this.officeKind === 'docx') {
      this.docxView()
    } else {
      this.xlsxView()
    }
  }

  /** A Word page: one reading column, with the same chrome as the chat. */
  @Builder
  docxView() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.docBlocks, (block: DocBlock, index: number) => {
          this.docxBlock(block, index)
        }, (block: DocBlock, index: number) =>
          `${index}.${block.kind}.${block.level}.${block.runs.length}.${block.rows.length}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(18)
      .backgroundColor($r('app.color.surface'))
      .borderRadius(16)
      .margin({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  /** One top-level Word block, with the emphasis the document carries. */
  @Builder
  docxBlock(block: DocBlock, index: number) {
    if (block.kind === DocBlockKind.HEADING) {
      Column() {
        this.richRuns(block.runs, block.level === 1 ? 22 : (block.level === 2 ? 19 : 17),
          $r('app.color.text_primary'), FontWeight.Bold, false)
      }
      .width('100%')
      .margin({ top: index === 0 ? 0 : 8, bottom: 2 })
    } else if (block.kind === DocBlockKind.BULLET) {
      Row({ space: 8 }) {
        Text('•')
          .fontSize(15)
          .fontColor(this.accent)
          .width(12)
          .textAlign(TextAlign.Center)
        Column() {
          this.richRuns(block.runs, 15, $r('app.color.text_primary'), FontWeight.Normal, false)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === DocBlockKind.NUMBERED) {
      Row({ space: 8 }) {
        Text('1.')
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .width(20)
        Column() {
          this.richRuns(block.runs, 15, $r('app.color.text_primary'), FontWeight.Normal, false)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === DocBlockKind.QUOTE) {
      Row({ space: 10 }) {
        Column()
          .width(3)
          .height(20)
          .borderRadius(2)
          .backgroundColor(this.accent)
        Column() {
          this.richRuns(block.runs, 14, $r('app.color.text_secondary'), FontWeight.Normal, true)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === DocBlockKind.CODE) {
      Text(block.runs.map((run: DocRun) => run.text).join(''))
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.surface_muted'))
        .borderRadius(8)
        .wordBreak(WordBreak.BREAK_ALL)
    } else if (block.kind === DocBlockKind.TABLE) {
      this.docxTable(block.rows)
    } else if (block.kind === DocBlockKind.RULE) {
      Divider()
        .color($r('app.color.divider'))
        .margin({ top: 6, bottom: 6 })
    } else {
      this.richRuns(block.runs, 15, $r('app.color.text_primary'), FontWeight.Normal, false)
    }
  }

  /** Inline runs; code spans take the accent, emphasis keeps its shape. */
  @Builder
  richRuns(runs: DocRun[], size: number, color: ResourceColor, weight: FontWeight, italicAll: boolean) {
    Text() {
      ForEach(runs, (run: DocRun, index: number) => {
        Span(run.text)
          .fontSize(size)
          .fontColor(run.code ? this.accent : color)
          .fontWeight(run.bold ? FontWeight.Bold : weight)
          .fontStyle(run.italic || italicAll ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(run.code ? 'monospace' : 'HarmonyOS Sans')
      }, (run: DocRun, index: number) =>
        `${index}.${run.text.length}.${run.bold}.${run.italic}.${run.code}`)
    }
    .width('100%')
    .lineHeight(size + 8)
    .wordBreak(WordBreak.BREAK_WORD)
  }

  /** A Word table; the header row is only tinted when a body row follows. */
  @Builder
  docxTable(rows: string[][]) {
    Column() {
      ForEach(rows, (row: string[], rowIndex: number) => {
        Row() {
          ForEach(row, (cell: string, column: number) => {
            Text(cell)
              .fontSize(13)
              .fontWeight(rowIndex === 0 && rows.length > 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor(rowIndex === 0 && rows.length > 1 ?
                $r('app.color.surface_muted') : Color.Transparent)
              .border({ width: 0.5, color: $r('app.color.divider') })
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (cell: string, column: number) => `${rowIndex}.${column}.${cell.length}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: string[], rowIndex: number) => `${rowIndex}.${row.length}`)
    }
    .width('100%')
    .border({ width: 0.5, color: $r('app.color.divider') })
    .borderRadius(8)
    .clip(true)
  }

  /** An Excel workbook: sheet tabs, then a scrollable grid. */
  @Builder
  xlsxView() {
    Column() {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.sheets, (sheet: SheetData, index: number) => {
            Text(sheet.name)
              .fontSize(13)
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(16)
              .fontColor(index === this.activeSheet ? Color.White : $r('app.color.text_secondary'))
              .backgroundColor(index === this.activeSheet ? this.accent : $r('app.color.surface_muted'))
              .onClick(() => {
                this.activeSheet = index
              })
          }, (sheet: SheetData, index: number) => `${index}.${sheet.name}`)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(48)
      .align(Alignment.TopStart)

      Divider()
        .color($r('app.color.divider'))

      if (this.activeSheet < this.sheets.length) {
        this.sheetGrid(this.sheets[this.activeSheet])
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  /** One worksheet: row numbers, column letters and the cell matrix. */
  @Builder
  sheetGrid(sheet: SheetData) {
    Column() {
      if (sheet.rows.length === 0) {
        Column() {
          Text('空工作表')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Scroll() {
            Column() {
              Row() {
                this.rowNumberCell('#')
                ForEach(this.sheetColumnNames(sheet), (name: string, index: number) => {
                  this.gridCell(name, true, false)
                }, (name: string, index: number) => `h.${index}`)
              }
              ForEach(sheet.rows, (row: string[], rowIndex: number) => {
                Row() {
                  this.rowNumberCell(`${rowIndex + 1}`)
                  ForEach(this.paddedRow(row, this.sheetColumnCount(sheet)), (cell: string, column: number) => {
                    this.gridCell(cell, rowIndex === 0, isNumericText(cell))
                  }, (cell: string, column: number) => `${rowIndex}.${column}.${cell.length}`)
                }
              }, (row: string[], rowIndex: number) => `${rowIndex}.${row.length}`)
            }
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 12, top: 8 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
      }
      if (sheet.truncated) {
        Text('仅显示前 300 行 / 40 列')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 12, top: 6, bottom: 8 })
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  rowNumberCell(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor($r('app.color.text_tertiary'))
      .width(40)
      .height(34)
      .textAlign(TextAlign.Center)
      .backgroundColor($r('app.color.surface_muted'))
      .border({ width: 0.5, color: $r('app.color.divider') })
  }

  @Builder
  gridCell(text: string, header: boolean, numeric: boolean) {
    Text(text)
      .fontSize(12)
      .fontWeight(header ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(header ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      .textAlign(numeric ? TextAlign.End : TextAlign.Start)
      .width(110)
      .height(34)
      .padding({ left: 8, right: 8 })
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .backgroundColor(header ? $r('app.color.surface_muted') : $r('app.color.surface'))
      .border({ width: 0.5, color: $r('app.color.divider') })
  }

  /** Widest row wins; the grid pads narrow rows so columns stay aligned. */
  private sheetColumnCount(sheet: SheetData): number {
    let count = 1
    for (const row of sheet.rows) {
      if (row.length > count) {
        count = row.length
      }
    }
    return count
  }

  private sheetColumnNames(sheet: SheetData): string[] {
    const names: string[] = []
    const count = this.sheetColumnCount(sheet)
    for (let index = 0; index < count; index++) {
      names.push(columnName(index))
    }
    return names
  }

  private paddedRow(row: string[], columns: number): string[] {
    const out: string[] = []
    for (let index = 0; index < columns; index++) {
      out.push(index < row.length ? row[index] : '')
    }
    return out
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
      } else if (this.kind === PreviewKind.OFFICE) {
        this.officeView()
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
