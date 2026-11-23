import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { webview } from '@kit.ArkWeb'
import { PythonRuntime } from '../common/PythonRuntime'
import { PythonHttpServer } from '../common/PythonHttpServer'

const DOMAIN = 0xD0042
const TAG = 'PythonHost'

/**
 * Hidden WebView that hosts the Pyodide interpreter.
 *
 * It is 1×1 and non-interactive: the user never sees Python, the `python_run`
 * tool drives it through the file bridge in `PythonRuntime`. Keeping the page
 * mounted for the app's lifetime is what makes the bridge synchronous enough
 * for a tool call; the interpreter itself still loads lazily on first use.
 */
@Component
export struct PythonHost {
  private controller: webview.WebviewController = new webview.WebviewController()
  private server: PythonHttpServer | null = null
  private baseUrl: string = ''
  private reloadCount: number = 0
  @State src: string = ''

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext
    PythonRuntime.get().attach(context, this.controller, () => {
      this.reloadCount++
      this.src = `${this.baseUrl}?r=${this.reloadCount}`
    })
    void this.boot(context)
  }

  aboutToDisappear(): void {
    PythonRuntime.get().detach()
    if (this.server !== null) {
      void this.server.stop()
      this.server = null
    }
  }

  private async boot(context: common.UIAbilityContext): Promise<void> {
    try {
      this.server = new PythonHttpServer(context)
      const port = await this.server.start()
      PythonRuntime.get().logEvent(`http server on ${port}`)
      this.baseUrl = `http://127.0.0.1:${port}/runner.html`
      this.src = `${this.baseUrl}?r=${this.reloadCount}`
    } catch (error) {
      const message = (error as Error).message
      hilog.error(DOMAIN, TAG, 'http server failed: %{public}s', message)
      PythonRuntime.get().logEvent(`http server failed: ${message}`)
      PythonRuntime.get().reportError(`Python 资源服务器启动失败：${message}`)
    }
  }

  build() {
    if (this.src.length > 0) {
      Web({ src: this.src, controller: this.controller })
        .javaScriptAccess(true)
        .fileAccess(true)
        .domStorageAccess(true)
        .javaScriptProxy({
          object: PythonRuntime.get().proxy(),
          name: 'dshHost',
          methodList: ['log', 'ready', 'pythonReady', 'pythonError', 'postResult'],
          controller: this.controller
        })
        .onPageEnd(() => {
          PythonRuntime.get().logEvent('page end')
          hilog.info(DOMAIN, TAG, 'runner page loaded')
        })
        .onConsole((event) => {
          PythonRuntime.get().logEvent(`console: ${event.message.getMessage()}`)
          hilog.info(DOMAIN, TAG, 'console: %{public}s', event.message.getMessage())
          return false
        })
        .onErrorReceive((event) => {
          PythonRuntime.get().logEvent(`web error: ${event.error.getErrorInfo()}`)
          hilog.error(DOMAIN, TAG, 'web error: %{public}s', event.error.getErrorInfo())
        })
        .onRenderExited(() => {
          PythonRuntime.get().onRenderExited()
        })
        .width(1)
        .height(1)
        .opacity(0.01)
        .hitTestBehavior(HitTestMode.None)
    }
  }
}
