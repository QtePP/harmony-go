import {
  ContextRecord,
  ContextSummary,
  ContextTurn,
  emptySummary,
  formatTokens,
  percentOf,
  shortModel,
  summarize
} from '../model/ContextLedger'

/**
 * The context panel: where the window went, and whether the prefix cache is
 * paying off.
 *
 * Opened from the context ring beside the composer (the ring already answers
 * "how full"; this answers "full of what"). It is a full-screen cover rather
 * than a sheet because the composition bar, the cache card and twelve turn
 * rows need vertical room, and a half-height sheet on a phone forces the
 * content into a nested scroll.
 *
 * All numbers come from the host ledger; this component renders and formats
 * only. The empty state is deliberately explicit about *why* there is no data
 * (a non-ACP profile has no ledger plugin), instead of showing zeroed charts.
 */
@Component
export struct ContextPanel {
  @StorageLink('accent') accent: string = '#4D6BFE'
  @Prop @Watch('onRecordsChanged') records: ContextRecord[] = []
  @Prop sessionTitle: string = ''
  onClose: () => void = () => {}
  onRefresh: () => void = () => {}

  @State summary: ContextSummary = emptySummary()

  private toolColor: string = '#E08A3C'
  private messageColor: string = '#2F9E5F'
  private cacheColor: string = '#0E9F8E'

  aboutToAppear(): void {
    this.recompute()
  }

  onRecordsChanged(): void {
    this.recompute()
  }

  private recompute(): void {
    this.summary = summarize(this.records)
  }

  private hasData(): boolean {
    return this.summary.records > 0
  }

  private occupancyPercent(): number {
    return percentOf(this.summary.context, this.summary.window)
  }

  private cachePercent(): number {
    return Math.round(this.summary.cacheHit * 100)
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

  private messagePercent(): number {
    return Math.max(0, 100 - this.systemPercent() - this.toolsPercent())
  }

  private turnCachePercent(turn: ContextTurn): number {
    const total = turn.input + turn.cacheRead + turn.cacheWrite
    return total > 0 ? Math.round((turn.cacheRead / total) * 100) : 0
  }

  /** One label/value pair in the composition legend. */
  @Builder
  legendRow(color: string, label: string, tokens: number, detail: string) {
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
      Text(detail)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
      Text(formatTokens(tokens))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width(58)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(24)
  }

  private turnMeta(turn: ContextTurn): string {
    const model = shortModel(turn.model)
    return model.length > 0 ? `${turn.steps} 步 · ${model}` : `${turn.steps} 步`
  }

  /** One turn row; sums across the steps that settlement used tools for. */
  @Builder
  turnRow(turn: ContextTurn) {
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
        Text(`缓存 ${this.turnCachePercent(turn)}% · 窗口 ${formatTokens(turn.context)}`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  card(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_tertiary'))
      .letterSpacing(0.4)
      .margin({ bottom: 8 })
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      Text('还没有上下文数据')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('跑一轮对话后，这里会显示窗口里装了什么、前缀缓存命中了多少。')
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

  build() {
    Column() {
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

      Scroll() {
        Column({ space: 16 }) {
          if (!this.hasData()) {
            this.emptyState()
          } else {
            // Occupancy: the one number that changes what the user does next.
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
                  .fontColor(this.occupancyPercent() >= 90 ? $r('app.color.status_danger')
                    : (this.occupancyPercent() >= 70 ? '#E08A3C' : this.accent))
              }
              .width('100%')

              Progress({ value: this.occupancyPercent(), total: 100, type: ProgressType.Linear })
                .width('100%')
                .height(6)
                .color(this.occupancyPercent() >= 90 ? $r('app.color.status_danger')
                  : (this.occupancyPercent() >= 70 ? '#E08A3C' : this.accent))
                .backgroundColor($r('app.color.surface_muted'))
                .style({ strokeWidth: 6 })

              Text('下一个请求会带上的上下文；70% 该考虑压缩，90% 接近硬顶。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(16)

            // Cache: the cost lever nobody can see without this panel.
            Row({ space: 14 }) {
              Column({ space: 2 }) {
                Text(`${this.cachePercent()}%`)
                  .fontSize(26)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.cacheColor)
                Text('前缀缓存命中')
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
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(16)

            // Composition: where the window actually went.
            Column({ space: 8 }) {
              this.card('窗口里是什么')
              Row() {
                Row()
                  .width(`${this.systemPercent()}%`)
                  .height('100%')
                  .backgroundColor(this.accent)
                Row()
                  .width(`${this.toolsPercent()}%`)
                  .height('100%')
                  .backgroundColor(this.toolColor)
                Row()
                  .width(`${this.messagePercent()}%`)
                  .height('100%')
                  .backgroundColor(this.messageColor)
              }
              .width('100%')
              .height(12)
              .borderRadius(6)
              .clip(true)
              .backgroundColor($r('app.color.surface_muted'))

              Column({ space: 2 }) {
                this.legendRow(this.accent, '系统提示', this.summary.system, `${this.systemPercent()}%`)
                this.legendRow(this.toolColor, '工具 schema', this.summary.tools, `${this.toolsPercent()}%`)
                this.legendRow(this.messageColor, '消息与工具结果', this.summary.messages, `${this.messagePercent()}%`)
              }
              .width('100%')
              .margin({ top: 4 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(16)

            // Turns: the last twelve, newest last.
            Column({ space: 2 }) {
              this.card(`最近 ${this.summary.turns.length} 轮`)
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

            Text('数据来自 dsh token-meter 的估算与 provider 返回的 usage；缓存命中 = 缓存读 /（未缓存输入 + 缓存读 + 缓存写）。只记计数，不上传。')
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
