import {
  ContextEvent,
  ContextPoint,
  ContextRecord,
  ContextSummary,
  ContextTurn,
  StepStat,
  emptySummary,
  eventKindLabel,
  formatDuration,
  formatTokens,
  percentOf,
  producerLabel,
  shortModel,
  summarize
} from '../model/ContextLedger'

/**
 * The context panel: where the window went, how it got there, and whether the
 * prefix cache is paying off.
 *
 * Opened from the context ring beside the composer (the ring already answers
 * "how full"; this answers "full of what, and what changed"). It is a
 * full-screen cover rather than a sheet because six cards need vertical room,
 * and a half-height sheet on a phone forces the content into a nested scroll.
 *
 * All numbers come from the host ledger; this component renders and formats
 * only. The empty state is deliberately explicit about *why* there is no data
 * (a non-ACP profile has no ledger plugin), instead of showing zeroed charts.
 */
@Component
export struct ContextPanel {
  @StorageLink('accent') accent: string = '#4D6BFE'
  @Prop @Watch('onDataChanged') records: ContextRecord[] = []
  @Prop @Watch('onDataChanged') events: ContextEvent[] = []
  @Prop @Watch('onDataChanged') steps: StepStat[] = []
  @Prop sessionTitle: string = ''
  onClose: () => void = () => {}
  onRefresh: () => void = () => {}
  /** Open the per-turn receipt (tokens, cache, tools) for one turn. */
  onOpenTurn: (turn: number) => void = () => {}

  @State summary: ContextSummary = emptySummary()
  /** Index into `summary.trend`; -1 means "the newest step". */
  @State selected: number = -1

  private systemColor: string = '#4D6BFE'
  private toolsColor: string = '#E08A3C'
  private userColor: string = '#2F9E5F'
  private injectedColor: string = '#8B5CF6'
  private assistantColor: string = '#0E9F8E'
  private resultColor: string = '#7C8698'
  private cacheColor: string = '#0E9F8E'
  /** Trend plot height in vp; bars scale against the session peak. */
  private plot: number = 76
  private barWidth: number = 10

  aboutToAppear(): void {
    this.recompute()
  }

  onDataChanged(): void {
    this.selected = -1
    this.recompute()
  }

  private recompute(): void {
    this.summary = summarize(this.records, this.events, this.steps)
  }

  private hasData(): boolean {
    return this.summary.records > 0
  }

  private occupancyPercent(): number {
    return percentOf(this.summary.context, this.summary.window)
  }

  /** Where auto-compaction will fire, as a percentage of the window. */
  private thresholdPercent(): number {
    return percentOf(this.summary.threshold, this.summary.window)
  }

  private occupancyColor(): ResourceColor {
    const percent = this.occupancyPercent()
    const threshold = this.thresholdPercent()
    if (threshold > 0 && percent >= threshold) {
      return $r('app.color.status_danger')
    }
    if (percent >= 70) {
      return '#E08A3C'
    }
    return this.accent
  }

  private cachePercent(): number {
    return Math.round(this.summary.cacheHit * 100)
  }

  /** Steady-state hit when there is something left after rebuilds, else the raw one. */
  private steadyPercent(): number {
    return this.summary.steadySamples > 0
      ? Math.round(this.summary.steadyHit * 100)
      : this.cachePercent()
  }

  private compositionTotal(): number {
    return this.summary.composed
  }

  private systemPercent(): number {
    return percentOf(this.summary.system, this.compositionTotal())
  }

  private toolsPercent(): number {
    return percentOf(this.summary.tools, this.compositionTotal())
  }

  private hasSplit(): boolean {
    return this.summary.splitUser + this.summary.splitAssistant
      + this.summary.splitToolResult + this.summary.splitInjected > 0
  }

  private userPercent(): number {
    return percentOf(this.summary.splitUser, this.compositionTotal())
  }

  private injectedPercent(): number {
    return percentOf(this.summary.splitInjected, this.compositionTotal())
  }

  private assistantPercent(): number {
    return percentOf(this.summary.splitAssistant, this.compositionTotal())
  }

  private resultPercent(): number {
    return percentOf(this.summary.splitToolResult, this.compositionTotal())
  }

  /** The selected trend point, or the newest one. */
  private selectedPoint(): ContextPoint | null {
    const points = this.summary.trend
    if (points.length === 0) {
      return null
    }
    if (this.selected >= 0 && this.selected < points.length) {
      return points[this.selected]
    }
    return points[points.length - 1]
  }

  /** The peak across the plotted points; bars scale against it. */
  private trendPeak(): number {
    let peak = 0
    for (const point of this.summary.trend) {
      peak = Math.max(peak, point.context)
    }
    return peak > 0 ? peak : 1
  }

  private barHeight(value: number): number {
    return Math.max(1, Math.round((value / this.trendPeak()) * this.plot))
  }

  /** Whether an event of this kind landed on the point's turn. */
  /** Dot under a bar: compaction red, injection accent, selection accent. */
  private dotColor(point: ContextPoint, index: number): ResourceColor {
    if (this.hasEvent(point, ['compact', 'prune'])) {
      return $r('app.color.status_danger')
    }
    if (this.hasEvent(point, ['inject']) || this.isSelected(index)) {
      return this.accent
    }
    return Color.Transparent
  }

  private hasEvent(point: ContextPoint, kinds: string[]): boolean {
    for (const event of this.summary.events) {
      if (event.turn === point.turn) {
        for (const kind of kinds) {
          if (event.kind === kind) {
            return true
          }
        }
      }
    }
    return false
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

  private eventDetail(event: ContextEvent): string {
    if (event.kind === 'model') {
      return shortModel(event.label)
    }
    if (event.kind === 'inject') {
      return producerLabel(event.label)
    }
    return event.label.length > 0 ? shortModel(event.label) : ''
  }

  private eventColor(kind: string): ResourceColor {
    if (kind === 'compact' || kind === 'prune') {
      return $r('app.color.status_danger')
    }
    if (kind === 'model') {
      return this.injectedColor
    }
    return this.accent
  }

  private turnCachePercent(turn: ContextTurn): number {
    const total = turn.input + turn.cacheRead + turn.cacheWrite
    return total > 0 ? Math.round((turn.cacheRead / total) * 100) : 0
  }

  private turnMeta(turn: ContextTurn): string {
    const model = shortModel(turn.model)
    return model.length > 0 ? `${turn.steps} 步 · ${model}` : `${turn.steps} 步`
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

  /** One label/value pair in the composition legend. */
  @Builder
  private legendRow(color: string, label: string, tokens: number, percent: number) {
    Row({ space: 8 }) {
      Column()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(color)
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(`${percent}%`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width(42)
        .textAlign(TextAlign.End)
      Text(formatTokens(tokens))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width(56)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(26)
  }

  /** One mini statistic in the strip under the occupancy card. */
  @Builder
  private stat(value: string, label: string) {
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
  private header() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('上下文')
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

      Text('刷新')
        .fontSize(13)
        .fontColor(this.accent)
        .height(36)
        .padding({ left: 10, right: 10 })
        .textAlign(TextAlign.Center)
        .onClick(() => this.onRefresh())

      Text('关闭')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .height(36)
        .padding({ left: 12, right: 12 })
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor($r('app.color.surface_muted'))
        .onClick(() => this.onClose())
    }
    .width('100%')
    .padding({ left: 2, right: 2, bottom: 14 })
  }

  @Builder
  private emptyState() {
    Column({ space: 10 }) {
      Text('还没有上下文数据')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('跑一轮对话后，这里会显示窗口里装了什么、它是怎么长起来的、前缀缓存命中了多少。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(20)
      Text('只在使用 ACP 连接方式时记录；SDK 兼容模式没有这份账本。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
        .lineHeight(18)
    }
    .width('100%')
    .padding({ top: 40, bottom: 40, left: 24, right: 24 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private occupancyCard() {
    Column({ space: 10 }) {
      Row() {
        Text(`${formatTokens(this.summary.context)} / ${formatTokens(this.summary.window)}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.occupancyPercent()}%`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.occupancyColor())
      }
      .width('100%')

      // The bar carries the compaction threshold as a tick, so "how full" and
      // "how close to compacting" are one reading instead of two cards.
      Stack({ alignContent: Alignment.Start }) {
        Progress({ value: this.occupancyPercent(), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color(this.occupancyColor())
          .backgroundColor($r('app.color.surface_muted'))
          .style({ strokeWidth: 6 })

        if (this.thresholdPercent() > 0 && this.thresholdPercent() < 100) {
          Row() {
            Column()
              .width(`${this.thresholdPercent()}%`)
              .height(1)
            Column()
              .width(2)
              .height(12)
              .borderRadius(1)
              .backgroundColor($r('app.color.status_danger'))
          }
          .width('100%')
          .height(12)
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .height(12)

      if (this.summary.threshold > 0) {
        Text(this.summary.reserved > 0
          ? `到 ${formatTokens(this.summary.threshold)}（${this.thresholdPercent()}%）自动压缩；另有 ${formatTokens(this.summary.reserved)} 留给回复。`
          : `到 ${formatTokens(this.summary.threshold)}（${this.thresholdPercent()}%）自动压缩。`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .lineHeight(16)
      } else {
        Text('下一个请求会带上的上下文。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private statsStrip() {
    Row({ space: 8 }) {
      this.stat(`${this.summary.totalTurns}`, '轮')
      this.stat(`${this.summary.records}`, '步')
      this.stat(`${this.summary.toolCalls}`, '工具调用')
      this.stat(formatDuration(this.summary.spanMs), '跨度')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private trendCard() {
    Column({ space: 8 }) {
      this.cardTitle('窗口怎么长起来的', `最近 ${this.summary.trend.length} 步`)
      Scroll() {
        Row({ space: 4 }) {
          ForEach(this.summary.trend, (point: ContextPoint, index: number) => {
            Column({ space: 2 }) {
              Column({ space: 0 }) {
                Column()
                  .width('100%')
                  .height(this.barHeight(point.messages))
                  .backgroundColor(this.resultColor)
                Column()
                  .width('100%')
                  .height(this.barHeight(point.tools))
                  .backgroundColor(this.toolsColor)
                Column()
                  .width('100%')
                  .height(this.barHeight(point.system))
                  .backgroundColor(this.systemColor)
              }
              .width(this.barWidth)
              .height(this.plot)
              .borderRadius(2)
              .clip(true)
              .backgroundColor($r('app.color.surface_muted'))
              .justifyContent(FlexAlign.End)

              // A dot marks a step where the window changed for a reason: a
              // compaction (red) or an injection (accent).
              Column()
                .width(4)
                .height(4)
                .borderRadius(2)
                .backgroundColor(this.dotColor(point, index))
            }
            .width(this.barWidth)
            .onClick(() => {
              this.selected = index
            })
          }, (point: ContextPoint) => `${point.turn}-${point.step}-${point.time}`)
        }
        .padding({ top: 2, bottom: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')
      .height(this.plot + 12)

      if (this.selectedPoint() !== null) {
        Row() {
          Text(`第 ${this.pointTurn()} 轮 · 第 ${this.pointStep()} 步`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text(`${formatTokens(this.pointContext())} · 较上一步 ${this.signed(this.pointDelta())}`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
      }

      Row({ space: 12 }) {
        this.seriesKey(this.systemColor, '系统')
        this.seriesKey(this.toolsColor, '工具 schema')
        this.seriesKey(this.resultColor, '消息')
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private seriesKey(color: string, label: string) {
    Row({ space: 5 }) {
      Column()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(color)
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
    }
  }

  private isSelected(index: number): boolean {
    return this.selected === index || (this.selected < 0 && index === this.summary.trend.length - 1)
  }

  private pointTurn(): number {
    const point = this.selectedPoint()
    return point === null ? 0 : point.turn
  }

  private pointStep(): number {
    const point = this.selectedPoint()
    return point === null ? 0 : point.step
  }

  private pointContext(): number {
    const point = this.selectedPoint()
    return point === null ? 0 : point.context
  }

  private pointDelta(): number {
    const point = this.selectedPoint()
    return point === null ? 0 : point.delta
  }

  @Builder
  private compositionCard() {
    Column({ space: 8 }) {
      this.cardTitle('窗口里是什么', '估算')
      Row() {
        Row()
          .width(`${this.systemPercent()}%`)
          .height('100%')
          .backgroundColor(this.systemColor)
        Row()
          .width(`${this.toolsPercent()}%`)
          .height('100%')
          .backgroundColor(this.toolsColor)
        if (this.hasSplit()) {
          Row()
            .width(`${this.userPercent()}%`)
            .height('100%')
            .backgroundColor(this.userColor)
          Row()
            .width(`${this.injectedPercent()}%`)
            .height('100%')
            .backgroundColor(this.injectedColor)
          Row()
            .width(`${this.assistantPercent()}%`)
            .height('100%')
            .backgroundColor(this.assistantColor)
          Row()
            .width(`${this.resultPercent()}%`)
            .height('100%')
            .backgroundColor(this.resultColor)
        } else {
          Row()
            .width(`${Math.max(0, 100 - this.systemPercent() - this.toolsPercent())}%`)
            .height('100%')
            .backgroundColor(this.userColor)
        }
      }
      .width('100%')
      .height(12)
      .borderRadius(6)
      .clip(true)
      .backgroundColor($r('app.color.surface_muted'))

      Column({ space: 2 }) {
        this.legendRow(this.systemColor, '系统提示', this.summary.system, this.systemPercent())
        this.legendRow(this.toolsColor, '工具 schema', this.summary.tools, this.toolsPercent())
        if (this.hasSplit()) {
          this.legendRow(this.userColor, '用户消息', this.summary.splitUser, this.userPercent())
          this.legendRow(this.injectedColor, '注入上下文', this.summary.splitInjected, this.injectedPercent())
          this.legendRow(this.assistantColor, '助手回复', this.summary.splitAssistant, this.assistantPercent())
          this.legendRow(this.resultColor, '工具结果', this.summary.splitToolResult, this.resultPercent())
        } else {
          this.legendRow(this.userColor, '消息与工具结果', this.summary.messages,
            Math.max(0, 100 - this.systemPercent() - this.toolsPercent()))
        }
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private cacheCard() {
    Row({ space: 14 }) {
      Column({ space: 2 }) {
        Text(`${this.steadyPercent()}%`)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.cacheColor)
        Text(this.summary.recomputes > 0 ? '前缀缓存命中 · 稳态' : '前缀缓存命中')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)

      Column({ space: 4 }) {
        Text(`${formatTokens(this.summary.totalCacheRead)} token 走了缓存`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
        Text(`未缓存输入 ${formatTokens(this.summary.totalInput)} · 写入 ${formatTokens(this.summary.totalCacheWrite)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
        if (this.summary.recomputes > 0) {
          Text(`未计入：${this.summary.recomputes} 次首步重算 ${formatTokens(this.summary.recomputeTokens)}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private eventsCard() {
    Column({ space: 4 }) {
      this.cardTitle('发生了什么', this.summary.events.length > 0 ? `最近 ${this.summary.events.length} 条` : '')
      if (this.summary.events.length === 0) {
        Text('还没有注入、模型切换或压缩。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: 2, bottom: 2 })
      } else {
        ForEach(this.summary.events, (event: ContextEvent) => {
          Row({ space: 8 }) {
            Column()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.eventColor(event.kind))
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
        }, (event: ContextEvent, index: number) => `${event.t}-${event.kind}-${event.turn}-${index}`)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  /** One turn row; sums across the steps that settlement used tools for. */
  @Builder
  private turnRow(turn: ContextTurn) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(`第 ${turn.turn} 轮`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(this.turnMeta(turn))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column({ space: 3 }) {
        Text(`入 ${formatTokens(turn.input)} · 出 ${formatTokens(turn.output)}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Text(turn.firstInput >= 1000
          ? `缓存 ${this.turnCachePercent(turn)}% · 首步 ${formatTokens(turn.firstInput)} 未命中`
          : `缓存 ${this.turnCachePercent(turn)}% · 窗口 ${formatTokens(turn.context)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.End)

      Text('›')
        .fontSize(16)
        .fontColor($r('app.color.text_tertiary'))
        .width(12)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .onClick(() => this.onOpenTurn(turn.turn))
  }

  @Builder
  private turnsCard() {
    Column({ space: 2 }) {
      this.cardTitle(`最近 ${this.summary.turns.length} 轮`, '点一轮看它花在哪')
      ForEach(this.summary.turns, (turn: ContextTurn) => {
        this.turnRow(turn)
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(0.5)
      }, (turn: ContextTurn) => `${turn.turn}-${turn.time}-${turn.context}`)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
  }

  @Builder
  private footnote() {
    Column({ space: 4 }) {
      Text('组成与拆分来自 dsh token-meter 的估算（按 provider 回报的总量归一），缓存命中 = 缓存读 /（未缓存输入 + 缓存读 + 缓存写）。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(17)
        .width('100%')
      Text('自动压缩阈值按 dsh 默认策略（窗口 80%、64k headroom）计算；事件只记生产者与 token 增减，不记内容，也不上传。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(17)
        .width('100%')
    }
    .width('100%')
  }

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: 12 }) {
          if (!this.hasData()) {
            this.emptyState()
          } else {
            this.occupancyCard()
            this.statsStrip()
            if (this.summary.trend.length > 1) {
              this.trendCard()
            }
            this.compositionCard()
            this.cacheCard()
            if (this.summary.events.length > 0) {
              this.eventsCard()
            }
            if (this.summary.steps > 0) {
              Column({ space: 2 }) {
                this.cardTitle('时间花在哪', '')
                Row({ space: 8 }) {
                  this.stat(formatDuration(Math.max(0, this.summary.stepMs - this.summary.toolMs)), '模型与等待')
                  this.stat(formatDuration(this.summary.toolMs), '工具执行')
                }
                .width('100%')
              }
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(16)
            }
            this.turnsCard()
            this.footnote()
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
