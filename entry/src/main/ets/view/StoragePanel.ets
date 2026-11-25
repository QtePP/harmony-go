import { common } from '@kit.AbilityKit'
import { AppConfig } from '../common/AppConfig'
import { StorageReport, StorageRow, StorageUsage } from '../common/StorageUsage'

const EMPTY_REPORT: StorageReport = {
  appSize: 0,
  dataSize: 0,
  cacheSize: 0,
  total: 0,
  rows: [],
  boundary: ''
}

/**
 * 「存储」— the honest receipt for the in-process runtime.
 *
 * The number that scares people away is the runtime, so the panel puts the
 * total first, then separates the three system buckets from the local detail
 * rows. It also owns the two reversible actions: clear cache, and queue a
 * payload rebuild for the next boot.
 */
@Component
export struct StoragePanel {
  @StorageLink('accent') accent: string = '#4D6BFE'

  @State report: StorageReport | null = null
  @State loading: boolean = true
  @State note: string = ''
  @State error: string = ''
  @State resetQueued: boolean = false

  onClose: () => void = () => {}

  aboutToAppear(): void {
    void this.load()
  }

  private async load(): Promise<void> {
    this.loading = true
    this.error = ''
    try {
      const context = getContext(this) as common.UIAbilityContext
      this.report = await StorageUsage.collect(context)
    } catch (error) {
      this.error = `统计失败：${String(error)}`
    } finally {
      this.loading = false
    }
  }

  private reportData(): StorageReport {
    return this.report === null ? EMPTY_REPORT : this.report
  }

  private showNote(text: string): void {
    this.note = text
    setTimeout(() => {
      if (this.note === text) {
        this.note = ''
      }
    }, 4200)
  }

  private confirmClearCache(): void {
    AlertDialog.show({
      message: '清理缓存会删除导出的长图、PDF 和分享临时文件；不会动工作区、会话、本体或正在接收的同步暂存。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '清理',
        action: () => {
          void this.clearCache()
        }
      },
      cancel: () => {}
    })
  }

  private async clearCache(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext
      const freed = await StorageUsage.clearCache(context)
      this.showNote(freed > 0 ? `已清理 ${StorageUsage.format(freed)}` : '没有可清理的缓存')
      await this.load()
    } catch (error) {
      this.showNote(`清理失败：${String(error)}`)
    }
  }

  private confirmReset(): void {
    AlertDialog.show({
      message: '重建会删除已解包的运行时（约 1GB），并在下次启动重新解包（约 1–2 分钟）。会话、工作区和本体不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '重建',
        action: () => this.requestReset()
      },
      cancel: () => {}
    })
  }

  private requestReset(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext
      AppConfig.requestPayloadReset(context)
      this.resetQueued = true
      this.showNote('已标记重建；请彻底退出并重新打开应用，下次启动会重新解包。')
    } catch (error) {
      this.showNote(`操作失败：${String(error)}`)
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
      }
      .width('100%')
      .padding({ right: 44 })

      Column({ space: 2 }) {
        Text('存储')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('安装包、运行时载荷、会话与缓存')
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
  private stat(name: string, bytes: number) {
    Column({ space: 2 }) {
      Text(name)
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
      Text(StorageUsage.format(bytes))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  private hero(report: StorageReport) {
    Column({ space: 12 }) {
      Text('本机占用')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))

      Row({ space: 6 }) {
        Text(StorageUsage.format(report.total))
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('系统口径')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .padding({ left: 6, right: 6, top: 2, bottom: 1 })
          .border({ width: 1, color: $r('app.color.divider') })
          .borderRadius(6)
          .margin({ bottom: 5 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Row({ space: 10 }) {
        this.stat('安装包', report.appSize)
        this.stat('应用数据（含缓存）', report.dataSize)
        this.stat('其中缓存', report.cacheSize)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private rowCard(row: StorageRow) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(row.label)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
        Text(row.note)
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
          .lineHeight(14)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(row.estimated ? `≈ ${StorageUsage.format(row.bytes)}` : StorageUsage.format(row.bytes))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private actions() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('刷新')
          .layoutWeight(1)
          .height(44)
          .fontSize(13)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            void this.load()
          })
        Button('清理缓存')
          .layoutWeight(1)
          .height(44)
          .fontSize(13)
          .backgroundColor($r('app.color.surface_muted'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.confirmClearCache())
      }
      .width('100%')

      Button(this.resetQueued ? '已排队重建（下次启动生效）' : '重建运行时载荷（下次启动生效）')
        .width('100%')
        .height(44)
        .fontSize(13)
        .backgroundColor($r('app.color.surface_muted'))
        .fontColor($r('app.color.status_danger'))
        .enabled(!this.resetQueued)
        .onClick(() => this.confirmReset())
    }
    .width('100%')
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
          Text('统计不到存储占用')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.error)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
          Button('重试')
            .fontSize(12)
            .height(38)
            .backgroundColor($r('app.color.surface_muted'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              void this.load()
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 18, right: 18 })
      } else {
        Scroll() {
          Column({ space: 10 }) {
            this.hero(this.reportData())

            Text('明细')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 4 })

            ForEach(this.reportData().rows, (row: StorageRow) => {
              this.rowCard(row)
            }, (row: StorageRow) => row.id)

            this.actions()

            Text(this.reportData().boundary)
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .lineHeight(15)
              .width('100%')
              .padding({ top: 2 })

            Text('运行时载荷是解包后的 Node + dsh；压缩副本在解包成功或下次启动时自动删除。')

            Text('本机实测系统口径把缓存算在应用数据里，所以总占用不重复加缓存；清理按钮只动 cacheDir。')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .lineHeight(15)
              .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 12 })
    .backgroundColor($r('app.color.background'))
  }
}
