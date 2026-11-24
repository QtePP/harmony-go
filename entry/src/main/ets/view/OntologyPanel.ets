import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { shareFile } from '../common/FileShare'

/**
 * One durable fact as the Node plugin writes it into snapshot.json.
 *
 * Keep this interface in sync with `lib/store.js` `publicFact` and
 * `lib/render.js` `buildSnapshot`; the panel is a read-only view and a
 * one-command delete channel, not a second source of truth.
 */
interface OntologyFact {
  id: string
  subject: string
  subject_id: string
  predicate: string
  object: string
  object_id: string | null
  object_kind: string
  qualifier: string
  confidence: number
  source: string
  observed_at: string
  pinned: boolean
}

interface DeletedFact {
  id: string
  subject: string
  predicate: string
  object: string
  qualifier: string
  retired_at: string
}

interface OntologyCounts {
  facts: number
  entities: number
  pinned: number
}

interface OntologyCommandResult {
  at: string
  ok: boolean
  message: string
}

interface OntologySnapshot {
  version: number
  updatedAt: string
  counts: OntologyCounts
  pinned: OntologyFact[]
  facts: OntologyFact[]
  deleted?: DeletedFact[]
  truncated: boolean
  lastCommand: OntologyCommandResult | null
}

/**
 * 「它知道什么」— the user-facing half of the on-device ontology.
 *
 * The Node plugin owns the database; this panel reads the snapshot it writes
 * and drops one JSON file per deletion into `ontology/commands/`. That split
 * keeps a single writer (SQLite is opened by Node) while still letting the
 * user audit and delete what the model has learned.
 *
 * The panel deliberately shows the *source* and the *date* on every row: a
 * memory the user cannot question is worse than no memory at all.
 */
@Component
export struct OntologyPanel {
  @StorageLink('accent') accent: string = '#4D6BFE'

  @State snapshot: OntologySnapshot | null = null
  @State deleted: DeletedFact[] = []
  @State showDeleted: boolean = false
  @State query: string = ''
  @State note: string = ''
  @State loading: boolean = true
  @State error: string = ''

  onClose: () => void = () => {}

  aboutToAppear(): void {
    this.load()
  }

  /** Read the snapshot the plugin writes after every mutation. */
  private load(): void {
    this.loading = true
    this.error = ''
    try {
      const context = getContext(this) as common.UIAbilityContext
      const path = `${context.filesDir}/dsh-home/ontology/snapshot.json`
      if (!fs.accessSync(path)) {
        this.snapshot = null
        this.error = '还没有生成本体快照：Node 运行时可能尚未就绪，或插件未加载。'
        return
      }
      const text = fs.readTextSync(path)
      this.snapshot = JSON.parse(text) as OntologySnapshot
      this.deleted = this.snapshot.deleted ?? []
    } catch (error) {
      this.snapshot = null
      this.deleted = []
      this.error = `读取失败：${String(error)}`
    } finally {
      this.loading = false
    }
  }

  private allFacts(): OntologyFact[] {
    if (this.snapshot === null) {
      return []
    }
    return this.snapshot.facts
  }

  private filteredFacts(): OntologyFact[] {
    const all = this.allFacts()
    const needle = this.query.trim().toLowerCase()
    if (needle.length === 0) {
      return all
    }
    return all.filter((fact: OntologyFact) => {
      const haystack = `${fact.subject} ${fact.predicate} ${fact.object} ${fact.qualifier}`.toLowerCase()
      return haystack.includes(needle)
    })
  }

  private footerLabel(): string {
    const snapshot = this.snapshot
    if (snapshot !== null && snapshot.truncated) {
      return '列表只显示最近 400 条；完整内容用「分享」导出。只存在本机沙箱，被注入的片段会随请求发给模型。'
    }
    return '只存在本机应用沙箱；被注入的硬约束会随请求发给模型。'
  }

  private hasFacts(): boolean {
    return this.snapshot !== null && this.snapshot.counts.facts > 0
  }

  private deletedLabel(fact: DeletedFact): string {
    const at = new Date(fact.retired_at)
    if (Number.isNaN(at.getTime())) {
      return `${fact.retired_at} 删除`
    }
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`
    return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())} ${pad(at.getHours())}:${pad(at.getMinutes())} 删除`
  }

  private countsLabel(): string {
    if (this.snapshot === null) {
      return ''
    }
    const counts = this.snapshot.counts
    return `${counts.facts} 条事实 · ${counts.entities} 个实体 · ${counts.pinned} 条硬约束`
  }

  private predicateLabel(predicate: string): string {
    switch (predicate) {
      case 'name': return '姓名'
      case 'nickname': return '昵称'
      case 'pronoun': return '称谓'
      case 'language': return '语言'
      case 'timezone': return '时区'
      case 'birthday': return '生日'
      case 'city': return '城市'
      case 'occupation': return '职业'
      case 'employer': return '单位'
      case 'allergy': return '过敏'
      case 'diet': return '饮食'
      case 'avoids': return '避免'
      case 'likes': return '喜欢'
      case 'dislikes': return '不喜欢'
      case 'communication_style': return '沟通偏好'
      case 'relation': return '关系'
      case 'works_on': return '项目'
      case 'member_of': return '组织'
      case 'goal': return '目标'
      case 'deadline': return '截止'
      case 'met_on': return '见面'
      case 'promised': return '承诺'
      case 'note': return '备注'
      default: return predicate
    }
  }

  private sourceLabel(source: string): string {
    if (source === 'user') {
      return '你告诉它的'
    }
    if (source === 'model') {
      return '它从对话里记的'
    }
    if (source === 'import') {
      return '导入'
    }
    return source
  }

  private showNote(text: string): void {
    this.note = text
    setTimeout(() => {
      if (this.note === text) {
        this.note = ''
      }
    }, 4000)
  }

  /** Ask once, then drop a command file the Node plugin drains. */
  private confirmDelete(fact: OntologyFact): void {
    AlertDialog.show({
      message: `删除这条记忆？\n\n${fact.subject} · ${this.predicateLabel(fact.predicate)} = ${fact.object}`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        action: () => this.deleteFact(fact)
      },
      cancel: () => {}
    })
  }

  private deleteFact(fact: OntologyFact): void {
    try {
      const context = getContext(this) as common.UIAbilityContext
      const dir = `${context.filesDir}/dsh-home/ontology/commands`
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true)
      }
      const file = `${dir}/${Date.now()}-${Math.floor(Math.random() * 1000000)}.json`
      const handle = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(handle.fd, JSON.stringify({ op: 'forget', factId: fact.id }))
      fs.closeSync(handle)
      this.showNote('已删除；模型下一轮起不会再看到这条。')
      // The plugin polls every 1.5s; reload just after the next tick.
      setTimeout(() => this.load(), 1800)
    } catch (error) {
      this.showNote(`删除失败：${String(error)}`)
    }
  }

  /** Queue one command file for the Node plugin. */
  private writeOperation(payload: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext
      const dir = `${context.filesDir}/dsh-home/ontology/commands`
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true)
      }
      const file = `${dir}/${Date.now()}-${Math.floor(Math.random() * 1000000)}.json`
      const handle = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(handle.fd, payload)
      fs.closeSync(handle)
    } catch (error) {
      this.showNote(`操作失败：${String(error)}`)
    }
  }

  /** Export a bundle into the default workspace so project sync can carry it. */
  private exportToWorkspace(): void {
    this.writeOperation(JSON.stringify({ op: 'export-bundle' }))
    this.showNote('已导出到 workspace/ontology/；用「项目同步」把它发给另一台设备。')
    setTimeout(() => this.load(), 2200)
  }

  /** Import the newest bundle a sync dropped into the workspace. */
  private importLatest(): void {
    this.writeOperation(JSON.stringify({ op: 'import-latest' }))
    this.showNote('已请求导入最新的 ontology-bundle；稍后刷新列表。')
    setTimeout(() => this.load(), 2400)
  }

  /** Share summary.md through the system panel (the user can send it to any app). */
  private async share(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext
      const path = `${context.filesDir}/dsh-home/ontology/summary.md`
      if (!fs.accessSync(path)) {
        this.showNote('还没有可分享的内容。')
        return
      }
      const message = await shareFile(context, path)
      this.showNote(message)
    } catch (error) {
      this.showNote(`分享失败：${String(error)}`)
    }
  }

  @Builder
  private header() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('‹ 设置')
          .fontSize(13)
          .fontColor(this.accent)
          .height(36)
          .onClick(() => this.onClose())
        Blank()
        // The sheet's own close control floats over the top-right corner; keep
        // this row short so the two never overlap on a phone.
        Text('分享')
          .fontSize(13)
          .fontColor(this.accent)
          .height(36)
          .padding({ left: 10, right: 10 })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            void this.share()
          })
      }
      .width('100%')
      .padding({ right: 44 })

      Column({ space: 2 }) {
        Text('它知道什么')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.countsLabel())
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
    .padding({ left: 2, right: 2, bottom: 12 })
  }

  @Builder
  private factCard(fact: OntologyFact) {
    Row({ space: 8 }) {
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Text(this.predicateLabel(fact.predicate))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          if (fact.pinned) {
            Text('硬约束')
              .fontSize(9)
              .fontColor(this.accent)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .border({ width: 1, color: this.accent })
              .borderRadius(6)
          }
          Text(fact.subject)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Text(fact.object)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`${fact.qualifier.length > 0 ? `${fact.qualifier} · ` : ''}${fact.observed_at.slice(0, 10)} · ${this.sourceLabel(fact.source)}`)
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('删除')
        .fontSize(12)
        .fontColor($r('app.color.status_danger'))
        .height(44)
        .width(46)
        .padding({ left: 4, right: 4 })
        .textAlign(TextAlign.Center)
        .onClick(() => this.confirmDelete(fact))
    }
    .width('100%')
    .padding({ left: 14, right: 10, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private deletedCard(fact: DeletedFact) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.predicateLabel(fact.predicate))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Text('已删除')
          .fontSize(9)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .border({ width: 1, color: $r('app.color.text_tertiary') })
          .borderRadius(6)
        Text(fact.subject)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      Text(fact.object)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(this.deletedLabel(fact))
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private emptyState() {
    Column({ space: 10 }) {
      Text(this.deleted.length > 0 ? '还没有有效记忆' : '还没有记忆')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('当你说出姓名、忌口、关系、项目或承诺时，它会记在这里。也可以直接说「记住……」。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(18)
      Text('硬约束（姓名、语言、过敏、饮食、沟通偏好）会在每个新会话开始前自动带上；其余内容只在需要时查询。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
        .lineHeight(16)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 18, right: 18 })
  }

  build() {
    Column() {
      this.header()

      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(10)
          .margin({ bottom: 8 })
      }

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(this.accent)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column({ space: 10 }) {
          Text('读取不到本体数据')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.error)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
          Button('重试')
            .fontSize(12)
            .height(34)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => this.load())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 18, right: 18 })
      } else if (!this.hasFacts()) {
        this.emptyState()
      } else {
        TextInput({ text: this.query, placeholder: '搜索姓名、关系、项目、承诺…' })
          .height(40)
          .fontSize(13)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 10 })
          .onChange((value: string) => {
            this.query = value
          })

        List({ space: 8 }) {
          ForEach(this.filteredFacts(), (fact: OntologyFact) => {
            ListItem() {
              this.factCard(fact)
            }
          }, (fact: OntologyFact) => fact.id)
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)

        if (this.query.trim().length > 0 && this.filteredFacts().length === 0) {
          Text('没有匹配的记忆')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 16 })
        }

        Text(this.footerLabel())
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: 10 })
      }

      if (this.deleted.length > 0) {
        Row({ space: 6 }) {
          Text(`最近删除 · ${this.deleted.length} 条`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(this.showDeleted ? '收起' : '展开')
            .fontSize(12)
            .fontColor(this.accent)
        }
        .width('100%')
        .height(36)
        .onClick(() => {
          this.showDeleted = !this.showDeleted
        })

        if (this.showDeleted) {
          Text('已删除的事实不再注入模型；聊天里的「已记住」是当时的回执，不会随删除改写。')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(14)
            .width('100%')
            .padding({ bottom: 6 })

          List({ space: 6 }) {
            ForEach(this.deleted, (fact: DeletedFact) => {
              ListItem() {
                this.deletedCard(fact)
              }
            }, (fact: DeletedFact) => fact.id)
          }
          .width('100%')
          .height(230)
          .edgeEffect(EdgeEffect.Spring)
        }
      }

      Row({ space: 16 }) {
        if (this.hasFacts() || this.deleted.length > 0) {
          Text('导出到工作区')
            .fontSize(12)
            .fontColor(this.accent)
            .height(40)
            .onClick(() => this.exportToWorkspace())
        }
        Text('导入最新同步包')
          .fontSize(12)
          .fontColor(this.accent)
          .height(40)
          .onClick(() => this.importLatest())
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 12 })
    .backgroundColor($r('app.color.background'))
  }
}
