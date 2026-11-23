/**
 * The long-press menu, in one place.
 *
 * Every long press in the app opens a custom `bindPopup` holding this panel —
 * the session rail, the message bubble, the file rows. They used to be split
 * between this popover (sessions) and the system ActionSheet
 * (`UIContext.showActionSheet`) for messages and files, and the two never
 * looked like the same product: the ActionSheet draws its own header, its own
 * cancel row and its own spacing, and it always rises from the bottom instead
 * of pointing at the thing that was pressed.
 *
 * Conventions kept identical to the original session menu:
 *   - 13pt rows, 3vp of breathing room, on the popup's own surface colour;
 *   - exactly one row tinted with the accent — the harmless action people
 *     actually came for;
 *   - destructive rows go after a divider, in the danger colour, with a
 *     one-line caption saying what cannot be undone.
 *
 * It is a `@Component`, and callers instantiate it from a `@Builder` method:
 * a struct or a global builder invoked directly inside the `bindPopup` lambda
 * is compiled as a plain function call and dies at runtime (two different
 * crashes: "class constructor cannot called without 'new'" and
 * "Cannot read property observeComponentCreation2 of undefined", both on
 * device 2026-11-23). Going through a @Builder method is the supported shape —
 * the same one the sheet builders already use.
 */
export interface MenuAction {
  /** Dispatch key. Never rendered: the caller switches on it. */
  id: string
  label: string
  /** Tint this row with the accent colour. Use it for one row only. */
  accent?: boolean
  /** Danger colour, and a divider is drawn above the row. */
  danger?: boolean
  /** Small caption under the row (the "cannot be undone" line). */
  note?: string
}

@Component
export struct PopoverMenu {
  actions: MenuAction[] = []
  /** Passed in rather than read from AppStorage: the caller already binds it. */
  accent: string = '#4D6BFE'
  onPick: (id: string) => void = () => {}

  private labelColor(action: MenuAction): ResourceColor {
    if (action.danger === true) {
      return $r('app.color.status_danger')
    }
    return action.accent === true ? this.accent : $r('app.color.text_primary')
  }

  build() {
    Column() {
      ForEach(this.actions, (action: MenuAction) => {
        Column({ space: 2 }) {
          if (action.danger === true) {
            Divider()
              .color($r('app.color.divider'))
              .margin({ top: 8, bottom: 8 })
          }

          // The pressable column excludes the divider above it: a divider
          // inside the pressable area turns a stray tap between rows into an
          // accidental rollback.
          Column({ space: 2 }) {
            Text(action.label)
              .fontSize(13)
              .fontColor(this.labelColor(action))
              .width('100%')
              .padding({ top: 3, bottom: 3 })
            if (action.note !== undefined && action.note.length > 0) {
              Text(action.note)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ bottom: 3 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .onClick(() => this.onPick(action.id))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (action: MenuAction) => action.id)
    }
    .width(224)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
  }
}
