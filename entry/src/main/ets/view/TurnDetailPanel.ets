import {
  ContextEvent,
  ContextRecord,
  StepStat,
  eventKindLabel,
  formatDuration,
  formatTokens,
  percentOf,
  producerLabel,
  shortModel
} from '../model/ContextLedger'
import { TraceMark, TurnDetail, TurnStep, TurnTool, emptyTurn, turnDetail } from '../model/TurnDetail'

/**
 * One turn, opened: what it cost, where its time went, and which tools ran.
 *
 * The panel's per-turn rows are the entry point; this page is the receipt. It
 * is a sibling overlay (like the context panel) rather than a sheet, because
 * the panel itself is already an in-tree overlay and a node can carry only one
 * modal binding on this page.
 *
 * All numbers come from the host ledger (`v:1` settlements, `k:"s"` steps,
 * `k:"e"` events); tool names, durations and digests come from the local chat
 * rows. This component only renders and expands, never reads a file.
 */
@Component
export struct TurnDetailPanel {
  @StorageLink('accent') accent: string = '#4D6BFE'
  @Prop @Watch('onDataChanged') records: ContextRecord[] = []
  @Prop @Watch('onDataChanged') events: ContextEvent[] = []
  @Prop @Watch('onDataChanged') steps: StepStat[] = []
  @Prop @Watch('onDataChanged') traces: TraceMark[] = []
  @Prop @Watch('onDataChanged') turn: number = 0
  @Prop sessionTitle: string = ''
  onClose: () => void = () => {}

  @State detail: TurnDetail = emptyTurn(0)
  /** `step:tool` of the expanded tool card; empty = all collapsed. */
  @State expanded: string = ''

  private systemColor: string = '#4D6BFE'
  private toolsColor: string = '#E08A3C'
  private resultColor: string = '#7C8698'
  private plot: number = 56
  private barWidth: number = 10

  aboutToAppear(): void {
    this.recompute()
  }

  onDataChanged(): void {
    this.expanded = ''
    this.recompute()
  }

  private recompute(): void {
    this.detail = turnDetail(this.records, this.steps, this.events, this.traces, this.turn)
  }

  private cachePercent(): number {
    return Math.round(this.detail.cacheHit * 100)
  }

  private occupancyPercent(): number {
    return percentOf(this.detail.context, this.detail.window)
  }

  private stepPeak(): number {
    let peak = 0
    for (const step of this.detail.steps) {
      peak = Math.max(peak, step.context)
    }
    return peak > 0 ? peak : 1
  }

  private barHeight(value: number): number {
    return Math.max(1, Math.round((value / this.stepPeak()) * this.plot))
  }

  /** Durations under a second read as `56ms`, not `0s`. */
  private msLabel(ms: number): string {
    if (ms <= 0) {
      return ''
    }
    return ms < 1000 ? `${Math.round(ms)}ms` : formatDuration(ms)
  }

  /** A first step that re-sent most of its prompt is worth naming, not hiding. */
  private showPrefixNote(): boolean {
    return this.detail.firstInput >= 1000 && this.detail.firstHit < 0.6
  }

  /** Cache hit of the second step, or -1 when there is none. */
  private laterHit(): number {
    if (this.detail.steps.length < 2) {
      return -1
    }
    const step = this.detail.steps[1]
    const total = step.input + step.cacheRead + step.cacheWrite
    return total > 0 ? Math.round((step.cacheRead / total) * 100) : -1
  }

  private prefixNote(): string {
    const later = this.laterHit()
    const base = '前缀缓存按整段前缀匹配：应用更新、切换模型、工具或系统提示变更，都会让改动处往后的内容全部重算。'
    if (later >= 0) {
      return `${base}这一轮第 2 步起回到 ${later}%。`
    }
    return `${base}这一轮只有一步，所以整轮命中 ${this.cachePercent()}%。`
  }

  @Builder
  private prefixCard() {
    Column({ space: 5 }) {
      Text(`第 1 步有 ${formatTokens(this.detail.firstInput)} 未命中`)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(this.prefixNote())
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(17)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  private stepLabel(step: TurnStep): string {
    const parts: string[] = [`第 ${step.step} 步`]
    const wall = this.msLabel(step.ms)
    if (wall.length > 0) {
      parts.push(wall)
    }
    const tools = this.msLabel(step.toolMs)
    if (tools.length > 0) {
      parts.push(`工具 ${tools}`)
    }
    return parts.join(' · ')
  }

  private stepMeta(step: TurnStep): string {
    const parts: string[] = []
    if (step.input > 0 || step.output > 0) {
      parts.push(`入 ${formatTokens(step.input)} · 出 ${formatTokens(step.output)}`)
    }
    const total = step.input + step.cacheRead + step.cacheWrite
    if (total > 0) {
      parts.push(`缓存 ${Math.round((step.cacheRead / total) * 100)}%`)
    }
    if (step.context > 0) {
      parts.push(`窗口 ${formatTokens(step.context)}`)
    }
    return parts.join(' · ')
  }

  private toolIndex(step: TurnStep, index: number): string {
    return `${step.step}:${index}`
  }

  private isExpanded(step: TurnStep, index: number): boolean {
    return this.expanded === this.toolIndex(step, index)
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'failed') {
      return $r('app.color.status_danger')
    }
    if (status === 'completed') {
      return $r('app.color.status_success')
    }
    return $r('app.color.text_tertiary')
  }

  private statusGlyph(status: string): string {
    if (status === 'failed') {
      return '✕'
    }
    if (status === 'completed') {
      return '✓'
    }
    return '…'
  }

  private eventDetail(event: ContextEvent): string {
    if (event.kind === 'model') {
      return shortModel(event.label)
    }
    if (event.kind === 'inject') {
      return producerLabel(event.label)
    }
    return event.label.length > 0 ? shortModel(event.label) : ''
  }

  private signed(value: number): string {
    if (value > 0) {
      return `+${formatTokens(value)}`
    }
    if (value < 0) {
      return `-${formatTokens(Math.abs(value))}`
    }
    return '0'
  }

  // ---------------------------------------------------------------- builders

  @Builder
  private cardTitle(title: string, trailing: string) {
    Row() {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_tertiary'))
        .letterSpacing(0.4)
      Blank()
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  private header() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(`第 ${this.detail.turn} 轮`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.sessionTitle.length > 0 ? this.sessionTitle : '当前会话')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('返回')
        .fontSize(13)
        .fontColor(this.accent)
        .height(36)
        .padding({ left: 10, right: 10 })
        .textAlign(TextAlign.Center)
        .onClick(() => this.onClose())
    }
    .width('100%')
    .padding({ left: 2, right: 2, bottom: 14 })
  }

  @Builder
  private summaryCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.metric(this.detail.durationMs > 0 ? formatDuration(this.detail.durationMs) : '—', '用时')
        this.metric(`${this.detail.steps.length}`, '步')
        this.metric(this.detail.hasTiming ? `${this.detail.toolCalls}` : '—', '工具调用')
        this.metric(`${this.cachePercent()}%`, '缓存命中')
      }
      .width('100%')
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)
      Row({ space: 8 }) {
        this.metric(formatTokens(this.detail.input), '未缓存输入')
        this.metric(formatTokens(this.detail.output), '输出')
        this.metric(formatTokens(this.detail.cacheRead), '缓存读')
        this.metric(formatTokens(this.detail.cacheWrite), '缓存写')
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private metric(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  private flowCard() {
    Column({ space: 8 }) {
      this.cardTitle('本轮的窗口', `结束于 ${formatTokens(this.detail.context)} / ${formatTokens(this.detail.window)}`)
      Row({ space: 4 }) {
        ForEach(this.detail.steps, (step: TurnStep) => {
          Column({ space: 3 }) {
            Column({ space: 0 }) {
              Column()
                .width('100%')
                .height(this.barHeight(step.messages))
                .backgroundColor(this.resultColor)
              Column()
                .width('100%')
                .height(this.barHeight(step.tools))
                .backgroundColor(this.toolsColor)
              Column()
                .width('100%')
                .height(this.barHeight(step.system))
                .backgroundColor(this.systemColor)
            }
            .width(this.barWidth)
            .height(this.plot)
            .borderRadius(2)
            .clip(true)
            .backgroundColor($r('app.color.surface_muted'))
            .justifyContent(FlexAlign.End)
            Text(`${step.step}`)
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width(this.barWidth)
        }, (step: TurnStep) => `${step.step}-${step.time}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private toolChip(step: TurnStep, tool: TurnTool, index: number) {
    Row({ space: 5 }) {
      Text(tool.name)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 140 })
      Text(this.statusGlyph(tool.status))
        .fontSize(11)
        .fontColor(this.statusColor(tool.status))
    }
    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
    .borderRadius(9)
    .backgroundColor($r('app.color.surface_muted'))
    .onClick(() => {
      const key = this.toolIndex(step, index)
      this.expanded = this.expanded === key ? '' : key
    })
  }

  /** Index of the expanded tool inside this step, or -1. */
  private expandedIndex(step: TurnStep): number {
    const parts = this.expanded.split(':')
    if (parts.length !== 2) {
      return -1
    }
    if (parts[0] !== `${step.step}`) {
      return -1
    }
    const index = Number.parseInt(parts[1], 10)
    return Number.isNaN(index) || index < 0 || index >= step.toolsUsed.length ? -1 : index
  }

  /** The expanded tool's argument digest and result head, full width. */
  @Builder
  private toolDetail(step: TurnStep, tool: TurnTool) {
    Column({ space: 6 }) {
      if (tool.input.length > 0) {
        Text(tool.input)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      if (tool.output.length > 0) {
        Text(tool.output)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Text('在对话里展开可以看到完整结果')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .margin({ top: 2, bottom: 4 })
    .borderRadius(10)
    .backgroundColor($r('app.color.background'))
  }

  @Builder
  private stepCard(step: TurnStep) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.stepLabel(step))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (step.model.length > 0) {
          Text(shortModel(step.model))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')

      if (this.stepMeta(step).length > 0) {
        Text(this.stepMeta(step))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }

      if (step.toolsUsed.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(step.toolsUsed, (tool: TurnTool, index: number) => {
            Column() {
              this.toolChip(step, tool, index)
            }
            .margin({ right: 6, bottom: 6 })
          }, (tool: TurnTool, index: number) => `${step.step}-${index}-${tool.name}`)
        }
        .width('100%')

        if (this.expandedIndex(step) >= 0) {
          this.toolDetail(step, step.toolsUsed[this.expandedIndex(step)])
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  private stepsCard() {
    Column({ space: 0 }) {
      this.cardTitle('各步与工具', this.detail.hasTools ? '' : (this.detail.hasTiming ? '没有本机轨迹' : '没有逐步计时'))
      ForEach(this.detail.steps, (step: TurnStep) => {
        this.stepCard(step)
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(0.5)
      }, (step: TurnStep) => `step-${step.step}-${step.time}`)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private eventsCard() {
    Column({ space: 4 }) {
      this.cardTitle('本轮发生', '')
      ForEach(this.detail.events, (event: ContextEvent) => {
        Row({ space: 8 }) {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.accent)
          Text(eventKindLabel(event.kind))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
          if (this.eventDetail(event).length > 0) {
            Text(this.eventDetail(event))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            Blank()
          }
          Text(event.d === 0 ? '' : this.signed(event.d))
            .fontSize(12)
            .fontColor(event.d < 0 ? $r('app.color.status_danger') : $r('app.color.text_secondary'))
        }
        .width('100%')
        .height(26)
      }, (event: ContextEvent, index: number) => `${event.t}-${event.kind}-${index}`)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private emptyOrPartial() {
    Column({ space: 10 }) {
      if (!this.detail.hasLedger) {
        Text('这一轮没有账本记录')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('上下文账本从 v2 起才逐步计时；更早的轮次只有对话本身，没有 token 与耗时的逐项记录。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .textAlign(TextAlign.Center)
      } else if (!this.detail.hasTiming) {
        Text('这一轮没有逐步计时')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('逐步耗时是账本 v2 才开始记的；没有每一步的时间窗，工具轨迹就无法确定属于哪一步，所以这里只显示整轮 token。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .textAlign(TextAlign.Center)
      } else if (!this.detail.hasTools) {
        Text('这一轮没有留下工具轨迹')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('token 与耗时来自账本；工具名与参数只保存在本机最近的消息里，缓存被清理后就不在这里了。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: 12 }) {
          if (!this.detail.hasLedger) {
            this.emptyOrPartial()
          } else {
            this.summaryCard()
            if (this.showPrefixNote()) {
              this.prefixCard()
            }
            if (this.detail.steps.length > 1) {
              this.flowCard()
            }
            this.stepsCard()
            if (!this.detail.hasTools) {
              this.emptyOrPartial()
            }
            if (this.detail.events.length > 0) {
              this.eventsCard()
            }
            Text('数字来自上下文账本，工具名与参数来自本机对话缓存；工具耗时按步汇总（宿主计时），chip 只标名字与状态；只在这台设备上，不上传。')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .lineHeight(17)
              .width('100%')
          }
        }
        .width('100%')
        .padding({ bottom: 28 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 52 })
    .backgroundColor($r('app.color.background'))
  }
}
