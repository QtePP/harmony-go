import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { shareFile } from '../common/FileShare'
import { MenuAction, PopoverMenu } from '../common/PopoverMenu'

/** One visible row of the flattened workspace tree. */
interface FileRow {
  name: string
  path: string
  isDir: boolean
  depth: number
  expanded: boolean
  sizeLabel: string
}

const MAX_ROWS = 500
const MAX_DEPTH = 4

/** Byte count to a short human label. */
function sizeLabelOf(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`
}

function byName(a: FileRow, b: FileRow): number {
  return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
}

/** One directory level: dirs first, then files; dotfiles skipped. */
function listChildren(dir: string): FileRow[] {
  const dirs: FileRow[] = []
  const files: FileRow[] = []
  let names: string[] = []
  try {
    names = fs.listFileSync(dir)
  } catch (error) {
    return []
  }
  for (const name of names) {
    if (name.length === 0 || name.startsWith('.')) {
      continue
    }
    const path = `${dir}/${name}`
    let stat: fs.Stat | null = null
    try {
      stat = fs.statSync(path)
    } catch (error) {
      continue
    }
    if (stat.isDirectory()) {
      const row: FileRow = { name: name, path: path, isDir: true, depth: 0, expanded: false, sizeLabel: '' }
      dirs.push(row)
    } else {
      const row: FileRow = {
        name: name, path: path, isDir: false, depth: 0, expanded: false,
        sizeLabel: sizeLabelOf(stat.size)
      }
      files.push(row)
    }
  }
  dirs.sort(byName)
  files.sort(byName)
  return dirs.concat(files)
}

/**
 * Project files browser: a tree of the current project's workspace — either
 * its sandbox dir or the user-granted bound directory (both are plain POSIX
 * paths). Dirs expand in place; tapping a file opens the viewer, and
 * long-pressing one offers the things a file needs next: send it to another
 * app, show where it lives, or delete it.
 */
@Component
export struct FilesPanel {
  /** Accent bound to AppStorage; every theme switch repaints without a restart. */
  @StorageLink('accent') accent: string = '#4D6BFE'

  @Prop projectName: string = ''
  @Prop workspacePath: string = ''
  @Prop @Watch('onTick') refreshTick: number = 0
  @State rows: FileRow[] = []
  @State missing: boolean = false
  /** Long-press menu: which row it is for, its rows, and where the finger was. */
  @State menuPath: string = ''
  @State menuActions: MenuAction[] = []
  @State menuX: number = 0
  @State menuY: number = 0
  onOpenFile: (path: string, name: string) => void = () => {}
  private expanded: Set<string> = new Set()

  aboutToAppear(): void {
    this.rescan()
  }

  private onTick(): void {
    this.rescan()
  }

  private rescan(): void {
    const out: FileRow[] = []
    if (this.workspacePath.length === 0) {
      this.missing = true
      this.rows = out
      return
    }
    this.missing = !fs.accessSync(this.workspacePath)
    if (!this.missing) {
      this.scanLevel(this.workspacePath, 0, out)
    }
    this.rows = out
  }

  /** Walk one level; recursion only follows expanded dirs, within the caps. */
  private scanLevel(dir: string, depth: number, out: FileRow[]): void {
    const children = listChildren(dir)
    for (const child of children) {
      if (out.length >= MAX_ROWS) {
        return
      }
      const isExpanded = this.expanded.has(child.path)
      const row: FileRow = {
        name: child.name, path: child.path, isDir: child.isDir, depth: depth,
        expanded: isExpanded, sizeLabel: child.sizeLabel
      }
      out.push(row)
      if (child.isDir && isExpanded && depth < MAX_DEPTH) {
        this.scanLevel(child.path, depth + 1, out)
      }
    }
  }

  private toggle(row: FileRow): void {
    if (this.expanded.has(row.path)) {
      this.expanded.delete(row.path)
    } else {
      this.expanded.add(row.path)
    }
    this.rescan()
  }

  /**
   * Long-press actions for one file.
   *
   * Share comes first because it is the reason this menu exists: the file list
   * is where a produced artifact is easiest to grab, and sending it somewhere
   * else used to require opening the viewer first. Copy-path and delete are the
   * two things that otherwise need a desktop.
   */
  private openRowActions(row: FileRow): void {
    this.menuPath = row.path
    this.menuActions = row.isDir ? this.dirMenu(row) : this.fileMenu(row)
  }

  /** Folder rows: expand/collapse is still the tap, the menu is for the rest. */
  private dirMenu(row: FileRow): MenuAction[] {
    const rows: MenuAction[] = [
      { id: 'toggle', label: row.expanded ? '收起' : '展开', accent: true },
      { id: 'copy-dir', label: '复制目录路径' }
    ]
    return rows
  }

  /** File rows: share first — grabbing a produced file is why this menu exists. */
  private fileMenu(row: FileRow): MenuAction[] {
    const rows: MenuAction[] = [
      { id: 'share', label: '分享到其他应用', accent: true },
      { id: 'open', label: '打开' },
      { id: 'copy-file', label: '复制文件路径' },
      {
        id: 'delete',
        label: '删除',
        danger: true,
        note: '删除后无法从应用内恢复。'
      }
    ]
    return rows
  }

  /** Popup content; see the note in PopoverMenu about not instantiating there. */
  @Builder
  menuPanel() {
    PopoverMenu({
      actions: this.menuActions,
      accent: this.accent,
      onPick: (id: string) => this.runRowAction(id)
    })
  }

  private runRowAction(id: string): void {
    const row = this.rowOf(this.menuPath)
    this.menuPath = ''
    if (row === undefined) {
      return
    }
    if (id === 'toggle') {
      this.toggle(row)
    } else if (id === 'copy-dir' || id === 'copy-file') {
      this.copyPath(row.path)
    } else if (id === 'share') {
      void this.share(row)
    } else if (id === 'open') {
      this.onOpenFile(row.path, row.name)
    } else if (id === 'delete') {
      this.confirmDelete(row)
    }
  }

  private rowOf(path: string): FileRow | undefined {
    for (const row of this.rows) {
      if (row.path === path) {
        return row
      }
    }
    return undefined
  }

  private async share(row: FileRow): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    const message = await shareFile(context, row.path)
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 })
  }

  private copyPath(path: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, path)
      pasteboard.getSystemPasteboard().setDataSync(data)
      this.getUIContext().getPromptAction().showToast({ message: '路径已复制', duration: 1600 })
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1600 })
    }
  }

  /**
   * Deleting is irreversible and the file may be the only copy of something
   * the model wrote, so it asks first and names the file in the question.
   */
  private confirmDelete(row: FileRow): void {
    this.getUIContext().showAlertDialog({
      title: '删除文件',
      message: `确定删除「${row.name}」？这个操作无法撤销，dsh 之后也读不到它了。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#D9534F',
        action: () => this.deleteFile(row)
      }
    })
  }

  private deleteFile(row: FileRow): void {
    try {
      fs.unlinkSync(row.path)
      const message = `已删除：${row.name}`
      this.rescan()
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 })
    } catch (error) {
      const failure = error as Error
      this.getUIContext().getPromptAction().showToast({
        message: `删除失败：${failure.message}`,
        duration: 2200
      })
    }
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('项目文件')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          Text(`${this.projectName} · ${this.workspacePath}`)
            .fontSize(11)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
          .onClick(() => this.rescan())
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 18, bottom: 10 })

      Divider().color($r('app.color.divider'))

      if (this.missing) {
        Column({ space: 8 }) {
          Text('工作区目录不存在')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text(this.workspacePath)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.rows.length === 0) {
        Column({ space: 8 }) {
          Text('工作区暂无文件')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text('对话中让 dsh 创建的文件会出现在这里')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.rows, (row: FileRow) => {
            ListItem() {
              // ListItem takes exactly one child, so the row and the popup
              // anchor share this wrapper.
              Column() {
                Row({ space: 6 }) {
                if (row.isDir) {
                  SymbolGlyph($r('sys.symbol.chevron_down'))
                    .fontSize(11)
                    .fontColor([$r('app.color.text_tertiary')])
                    .rotate({ angle: row.expanded ? 90 : 0 })
                    .animation({ duration: 140, curve: Curve.EaseOut })
                } else {
                  Row().width(11)
                }

                SymbolGlyph(row.isDir ? $r('sys.symbol.folder_fill') : $r('sys.symbol.doc_text'))
                  .fontSize(16)
                  .fontColor([row.isDir ? this.accent : $r('app.color.text_secondary')])

                Text(row.name)
                  .fontSize(14)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .fontColor($r('app.color.text_primary'))

                if (!row.isDir && row.sizeLabel.length > 0) {
                  Text(row.sizeLabel)
                    .fontSize(11)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .width('100%')
              .padding({ left: 14 + row.depth * 14, right: 14, top: 9, bottom: 9 })
              .borderRadius(10)
              .onTouch((event: TouchEvent) => {
                // Anchor the menu at the finger, like every other long press.
                if (event.type === TouchType.Down && event.touches.length > 0) {
                  this.menuX = event.touches[0].x
                  this.menuY = event.touches[0].y
                }
              })
              .onClick(() => {
                if (row.isDir) {
                  this.toggle(row)
                } else {
                  this.onOpenFile(row.path, row.name)
                }
              })
              .gesture(LongPressGesture().onAction(() => this.openRowActions(row)))

              Column()
                .width(1)
                .height(1)
                .position({ x: this.menuX, y: this.menuY })
                .hitTestBehavior(HitTestMode.None)
                .bindPopup(this.menuPath === row.path && this.menuActions.length > 0, {
                  builder: (): void => {
                    this.menuPanel()
                  },
                  placement: Placement.Bottom,
                  popupColor: $r('app.color.surface'),
                  enableArrow: true,
                  autoCancel: true,
                  onStateChange: (state: PopupStateChangeParam) => {
                    if (!state.isVisible) {
                      this.menuPath = ''
                    }
                  }
                })
              }
              .width('100%')
            }
          }, (row: FileRow) => `${row.path}.${row.expanded}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 12 })
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
  }
}
