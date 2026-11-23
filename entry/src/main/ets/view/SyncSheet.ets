import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { ProjectStore, ProjectSummary } from '../model/ProjectModel'
import { SessionExport, SessionStore, SessionSummary } from '../model/ChatModel'
import {
  collectEntries, removeTree, sendProject, SYNC_PORT, SyncProgress, SyncReceiver, SyncReport,
  totalBytes
} from '../common/ProjectSync'
import { localLanAddress } from '../common/Interop'

/**
 * Project sync sheet: hand a project's files to another device.
 *
 * Two halves in one place because they are the same conversation: the receiver
 * opens a window and reads out a code, the sender types the code and an
 * address. Everything else is progress.
 *
 * The file list shows the workspace's top-level entries with checkboxes rather
 * than a deep tree: a project is usually one or two folders plus a few files,
 * and a full tree with tri-state boxes is a lot of UI to get wrong. Unchecked
 * top-level entries are simply not walked.
 */
@Component
export struct SyncSheet {
  @State projects: ProjectSummary[] = []
  @State projectId: string = ProjectStore.DEFAULT_ID
  @State topLevel: string[] = []
  @State selected: string[] = []
  @State allFiles: boolean = true
  @State mode: string = 'send'
  @State host: string = ''
  @State code: string = ''
  @State busy: boolean = false
  @State progress: SyncProgress | null = null
  @State message: string = ''
  @State receiveCode: string = ''
  @State receiveAddress: string = ''
  @State report: SyncReport | null = null
  @State sessions: SessionSummary[] = []
  @State selectedSessions: string[] = []
  private sessionStore: SessionStore = new SessionStore()
  @StorageLink('accent') accent: string = '#4D6BFE'
  onClose: () => void = () => {}
  private receiver: SyncReceiver | null = null
  private cancelRequested: boolean = false

  aboutToAppear(): void {
    void this.loadProjects()
  }

  /** Conversations of the selected project, offered as an optional payload. */
  private async loadSessions(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    await this.sessionStore.init(context)
    this.sessions = await this.sessionStore.list(this.projectId)
    this.selectedSessions = []
  }

  aboutToDisappear(): void {
    this.cancelRequested = true
    if (this.receiver !== null) {
      void this.receiver.close()
      removeTree(`${(getContext(this) as common.UIAbilityContext).cacheDir}/sync-incoming`)
      this.receiver = null
    }
  }

  private async loadProjects(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    const store = new ProjectStore()
    await store.init(context)
    this.projects = await store.list()
    if (this.projects.length > 0) {
      this.projectId = this.projects[0].id
      this.loadTopLevel()
      void this.loadSessions()
    }
  }

  private workspace(): string {
    const context = getContext(this) as common.UIAbilityContext
    return ProjectStore.workspaceDir(context, this.projectId)
  }

  /** Names directly under the workspace: what the checkbox list shows. */
  private loadTopLevel(): void {
    const root = this.workspace()
    try {
      const names = fs.listFileSync(root)
      names.sort((a: string, b: string) => a.localeCompare(b))
      this.topLevel = names
    } catch (error) {
      this.topLevel = []
    }
    this.selected = []
  }

  private chosen(): string[] {
    return this.allFiles ? [] : this.selected
  }

  /** Display name of the selected project, for the hello frame. */
  private projectName(): string {
    for (const project of this.projects) {
      if (project.id === this.projectId) {
        return project.name
      }
    }
    return '项目'
  }

  private summaryLine(): string {
    const entries = collectEntries(this.workspace(), this.chosen(), [])
    const bytes = totalBytes(entries)
    const sessions = this.selectedSessions.length > 0 ? ` · ${this.selectedSessions.length} 个会话` : ''
    return `${entries.length} 个文件 · ${this.sizeText(bytes)}${sessions}`
  }

  private sizeText(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`
    }
    if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`
    }
    return `${bytes} B`
  }

  private percent(): number {
    const progress = this.progress
    if (progress === null || progress.bytesTotal <= 0) {
      return 0
    }
    return Math.min(100, Math.floor(progress.bytesDone * 100 / progress.bytesTotal))
  }

  private async startSend(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    if (this.host.trim().length === 0 || this.code.trim().length === 0) {
      this.message = '先填对方地址和配对码（对方在「接收」页面上显示）'
      return
    }
    const skipped: string[] = []
    const entries = collectEntries(this.workspace(), this.chosen(), skipped)
    if (entries.length === 0 && this.selectedSessions.length === 0) {
      this.message = '这个项目没有可发送的文件，也没有勾选会话'
      return
    }
    let sessionsJson = ''
    if (this.selectedSessions.length > 0) {
      const packed = await this.sessionStore.exportSessions(this.selectedSessions)
      sessionsJson = packed.length > 0 ? JSON.stringify(packed) : ''
    }
    this.busy = true
    this.cancelRequested = false
    this.message = skipped.length > 0 ? `跳过 ${skipped.length} 项（过大或不可读）` : ''
    this.progress = {
      phase: 'connect', filesDone: 0, filesTotal: entries.length,
      bytesDone: 0, bytesTotal: totalBytes(entries), detail: '正在连接'
    }
    const parts = this.host.trim().split(':')
    const host = parts[0]
    const port = parts.length > 1 ? Number(parts[1]) : SYNC_PORT
    try {
      const report = await sendProject(
        this.workspace(), entries, host, port, this.code.trim(),
        this.projectName(), sessionsJson,
        (progress: SyncProgress) => {
          this.progress = progress
        },
        () => this.cancelRequested
      )
      this.report = report
      this.message = `已发送 ${report.files} 个文件 · ${this.sizeText(report.bytes)}`
    } catch (error) {
      this.message = `发送失败：${(error as Error).message}`
    } finally {
      this.busy = false
      this.cancelRequested = false
    }
  }

  /** Take the conversations frame the sender attached, if any. */
  private async importSessions(json: string): Promise<void> {
    let packed: SessionExport[] = []
    try {
      packed = JSON.parse(json) as SessionExport[]
    } catch (error) {
      return
    }
    if (!(packed instanceof Array) || packed.length === 0) {
      return
    }
    const added = await this.sessionStore.importSessions(packed, this.projectId)
    this.message = added > 0 ? `已导入 ${added} 个会话` : '会话都已存在，未覆盖'
    await this.loadSessions()
  }

  private async startReceive(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext
    if (this.receiver !== null) {
      await this.receiver.close()
      this.receiver = null
      this.receiveCode = ''
      return
    }
    const receiver = new SyncReceiver()
    this.receiver = receiver
    this.busy = true
    this.report = null
    this.message = ''
    this.receiveAddress = await localLanAddress()
    try {
      const port = await receiver.open(
        context,
        this.workspace(),
        (progress: SyncProgress) => {
          this.progress = progress
        },
        (json: string) => {
          void this.importSessions(json)
        },
        (report: SyncReport, error: string) => {
          this.busy = false
          this.receiveCode = ''
          this.receiver = null
          if (error.length > 0) {
            this.message = error
            return
          }
          this.report = report
          const skipped = report.skipped.length > 0 ? `；跳过 ${report.skipped.length} 个已存在的文件` : ''
          this.message = `已接收 ${report.files} 个文件 · ${this.sizeText(report.bytes)}${skipped}`
          this.loadTopLevel()
        }
      )
      this.receiveCode = receiver.pairCode
      this.message = `等待对方连接（端口 ${port}）`
    } catch (error) {
      this.busy = false
      this.receiver = null
      this.message = `无法开始接收：${(error as Error).message}`
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
      Row() {
        Text('项目同步').fontSize(18).fontWeight(FontWeight.Medium)
        Blank()
        Button('关闭')
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.receiver !== null) {
              void this.receiver.close()
              this.receiver = null
            }
            this.receiveCode = ''
            this.onClose()
          })
      }
      .width('100%')

      // 项目
      Column({ space: 6 }) {
        Text('项目').fontSize(12).fontColor($r('app.color.text_secondary'))
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.projects, (project: ProjectSummary) => {
            Text(project.name)
              .fontSize(12)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .backgroundColor(project.id === this.projectId ?
                $r('app.color.surface_muted') : $r('app.color.background'))
              .fontColor(project.id === this.projectId ?
                $r('app.color.text_primary') : $r('app.color.text_secondary'))
              .borderRadius(14)
              .margin({ right: 8, bottom: 6 })
              .onClick(() => {
                if (this.busy) {
                  return
                }
                this.projectId = project.id
                this.progress = null
                this.report = null
                this.message = ''
                this.loadTopLevel()
                void this.loadSessions()
              })
          }, (project: ProjectSummary) => project.id)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 内容
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text('内容').fontSize(12).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(this.summaryLine()).fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        Row({ space: 8 }) {
          Text(this.allFiles ? '☑' : '☐')
            .fontSize(16)
            .fontColor(this.allFiles ? this.accent : $r('app.color.text_secondary'))
          Text('全部文件').fontSize(13)
        }
        .width('100%')
        .onClick(() => {
          if (!this.busy) {
            this.allFiles = !this.allFiles
          }
        })
        if (!this.allFiles) {
          Column({ space: 2 }) {
            ForEach(this.topLevel, (name: string) => {
              Row({ space: 8 }) {
                Text(this.selected.includes(name) ? '☑' : '☐')
                  .fontSize(16)
                  .fontColor(this.selected.includes(name) ? this.accent : $r('app.color.text_secondary'))
                Text(name).fontSize(13)
                Blank()
              }
              .width('100%')
              .onClick(() => {
                if (this.busy) {
                  return
                }
                if (this.selected.includes(name)) {
                  this.selected = this.selected.filter((item: string) => item !== name)
                } else {
                  this.selected = this.selected.concat([name])
                }
              })
            }, (name: string) => name)
          }
          .width('100%')
          .padding(8)
          .backgroundColor($r('app.color.surface_muted'))
          .borderRadius(8)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 会话（可选）：只带本地缓存的消息，不同步服务端日志
      if (this.sessions.length > 0) {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text('会话（可选）').fontSize(12).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.selectedSessions.length > 0 ? `已选 ${this.selectedSessions.length} 个` : '不带会话')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          ForEach(this.sessions, (session: SessionSummary) => {
            Row({ space: 8 }) {
              Text(this.selectedSessions.includes(session.id) ? '☑' : '☐')
                .fontSize(16)
                .fontColor(this.selectedSessions.includes(session.id) ?
                  this.accent : $r('app.color.text_secondary'))
              Text(session.title.length > 0 ? session.title : session.id)
                .fontSize(13)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .onClick(() => {
              if (this.busy) {
                return
              }
              if (this.selectedSessions.includes(session.id)) {
                this.selectedSessions = this.selectedSessions.filter((item: string) => item !== session.id)
              } else {
                this.selectedSessions = this.selectedSessions.concat([session.id])
              }
            })
          }, (session: SessionSummary) => session.id)
          Text('只同步本地缓存的消息（最近 200 条）；图片不随会话走。导入的会话标题带「（导入）」。')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.surface_muted'))
        .borderRadius(8)
      }

      // 模式
      Row({ space: 8 }) {
        Button('发送')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(this.mode === 'send' ? this.accent : $r('app.color.surface_muted'))
          .fontColor(this.mode === 'send' ? Color.White : $r('app.color.text_primary'))
          .onClick(() => {
            if (!this.busy) {
              this.mode = 'send'
            }
          })
        Button('接收')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(this.mode === 'receive' ? this.accent : $r('app.color.surface_muted'))
          .fontColor(this.mode === 'receive' ? Color.White : $r('app.color.text_primary'))
          .onClick(() => {
            if (!this.busy) {
              this.mode = 'receive'
            }
          })
      }
      .width('100%')

      if (this.mode === 'send') {
        Column({ space: 8 }) {
          TextInput({ text: this.host, placeholder: '对方地址，如 192.168.1.5:4519' })
            .fontSize(14)
            .height(42)
            .onChange((value: string) => {
              this.host = value
            })
          TextInput({ text: this.code, placeholder: '对方显示的 6 位配对码' })
            .fontSize(14)
            .height(42)
            .type(InputType.Number)
            .onChange((value: string) => {
              this.code = value
            })
          Button(this.busy ? '发送中…' : '开始发送')
            .width('100%')
            .height(42)
            .fontSize(14)
            .backgroundColor(this.accent)
            .fontColor(Color.White)
            .enabled(!this.busy)
            .onClick(() => {
              void this.startSend()
            })
        }
        .width('100%')
      } else {
        Column({ space: 8 }) {
          Text(this.receiveAddress.length > 0 ?
            `本机地址：${this.receiveAddress}（端口 ${SYNC_PORT}）` : '本机不在局域网内，接收方需要同一 WiFi')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          if (this.receiveCode.length > 0) {
            Text(`配对码：${this.receiveCode}`)
              .fontSize(24)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.accent)
              .width('100%')
              .textAlign(TextAlign.Center)
            Text('让对方在「发送」里填上面的地址与这个码')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          Button(this.receiver !== null ? '停止接收' : '开始接收')
            .width('100%')
            .height(42)
            .fontSize(14)
            .backgroundColor(this.receiver !== null ?
              $r('app.color.surface_muted') : this.accent)
            .fontColor(this.receiver !== null ? $r('app.color.text_primary') : Color.White)
            .onClick(() => {
              void this.startReceive()
            })
          Text('接收到的文件只写进项目工作区；同名文件不覆盖，会列在结果里。')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .width('100%')
      }

      if (this.progress !== null) {
        Column({ space: 4 }) {
          Row() {
            Text(this.progress === null ? '' : this.progress.phase === 'send' ? '发送中' : '接收中')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.percent()}%`).fontSize(12).fontColor(this.accent)
          }
          .width('100%')
          Progress({ value: this.percent(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .color(this.accent)
        }
        .width('100%')
      }

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      if (this.report !== null && (this.report as SyncReport).skipped.length > 0) {
        Text(`已存在、未覆盖：${(this.report as SyncReport).skipped.join('、')}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }
}
