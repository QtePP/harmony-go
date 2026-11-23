import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { webview } from '@kit.ArkWeb'

const DOMAIN = 0xD0042
const TAG = 'PythonRuntime'
const POLL_MS = 250

/** Methods the runner page may call through `javaScriptProxy`. */
export interface PythonHostProxy {
  log(line: string): void
  ready(): void
  pythonReady(version: string): void
  pythonError(message: string): void
  postResult(id: string, payload: string): void
}

/** One pending `python_run` request, written by the dsh plugin. */
class PythonFile {
  name: string = ''
  data: string = ''
}

class PythonRequest {
  id: string = ''
  code: string = ''
  timeoutMs: number = 90000
  files: PythonFile[] = []
  packages: string[] = ['pandas']
}

/** Readiness record consumed by the dsh plugin for a useful error message. */
class PythonStatus {
  ok: boolean = false
  version: string = ''
  error: string = ''
  updatedAt: number = 0

  constructor(ok: boolean, version: string, error: string, updatedAt: number) {
    this.ok = ok
    this.version = version
    this.error = error
    this.updatedAt = updatedAt
  }
}

/** Concrete proxy: ArkTS rejects object literals with method properties. */
class PythonBridgeProxy implements PythonHostProxy {
  private runtime: PythonRuntime

  constructor(runtime: PythonRuntime) {
    this.runtime = runtime
  }

  log(line: string): void {
    this.runtime.onLog(line)
  }

  ready(): void {
    this.runtime.onReady()
  }

  pythonReady(version: string): void {
    this.runtime.onPythonReady(version)
  }

  pythonError(message: string): void {
    this.runtime.onPythonError(message)
  }

  postResult(id: string, payload: string): void {
    this.runtime.onPostResult(id, payload)
  }
}

/**
 * Host side of the on-device Python bridge.
 *
 * The interpreter is Pyodide running inside the app's WebView (see
 * `view/PythonHost.ets` and `rawfile/pyodide/runner.html`). The dsh plugin
 * cannot call ArkTS directly, so both sides meet on a tiny file protocol:
 *
 *   <filesDir>/dsh-home/python/req/req-<id>.json   plugin → app
 *   <filesDir>/dsh-home/python/res/res-<id>.json   app → plugin
 *   <filesDir>/dsh-home/python/status.json         readiness / last error
 *
 * This is slower than an RPC but it is dead simple, survives either side not
 * being ready yet, and needs no listening port. The WebView itself is hidden
 * and 1×1; Pyodide is loaded lazily on the first run, so an unused Python
 * feature costs no memory.
 */
export class PythonRuntime {
  private static instance: PythonRuntime = new PythonRuntime()

  private context: common.UIAbilityContext | null = null
  private controller: webview.WebviewController | null = null
  private timer: number = -1
  private bridgeReady: boolean = false
  private pythonVersion: string = ''
  /** req file name → wall-clock deadline for the run. */
  private inflight: Map<string, number> = new Map<string, number>()
  private baseDir: string = ''
  private loggedRun: number = 0
  private reloadPage: () => void = () => {}

  static get(): PythonRuntime {
    return PythonRuntime.instance
  }

  /** Bind the hidden WebView once the page exists. */
  attach(context: common.UIAbilityContext, controller: webview.WebviewController,
    reloadPage: () => void): void {
    this.context = context
    this.controller = controller
    this.reloadPage = reloadPage
    this.baseDir = `${context.filesDir}/dsh-home/python`
    this.ensureDirs()
    this.writeStatus(false, '', '')
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        this.tick()
      }, POLL_MS)
    }
    hilog.info(DOMAIN, TAG, 'attached: %{public}s', this.baseDir)
  }

  detach(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer)
      this.timer = -1
    }
    this.controller = null
    this.context = null
    this.bridgeReady = false
  }

  /** Proxy object injected into the page as `dshHost`. */
  proxy(): PythonHostProxy {
    return new PythonBridgeProxy(this)
  }

  /** Runner page log line. */
  onLog(line: string): void {
    hilog.info(DOMAIN, TAG, 'web: %{public}s', line)
  }

  /** The page is mounted and can accept runs; Python itself is still lazy. */
  onReady(): void {
    this.bridgeReady = true
    this.logEvent('bridge ready')
    hilog.info(DOMAIN, TAG, 'bridge ready')
  }

  /** Pyodide finished loading. */
  onPythonReady(version: string): void {
    this.pythonVersion = version
    this.writeStatus(true, version, '')
    this.logEvent(`python ready: ${version}`)
    hilog.info(DOMAIN, TAG, 'python ready: %{public}s', version)
  }

  /** Pyodide failed to load; persist the reason for `python_run`. */
  onPythonError(message: string): void {
    this.writeStatus(false, this.pythonVersion, message)
    this.logEvent(`python failed: ${message}`)
    hilog.error(DOMAIN, TAG, 'python failed: %{public}s', message)
  }

  /** One finished run, as a JSON string from the page. */
  onPostResult(id: string, payload: string): void {
    this.onResult(id, payload)
  }

  /** Surface a host-side failure (e.g. the loopback server could not bind). */
  reportError(message: string): void {
    this.writeStatus(false, this.pythonVersion, message)
    hilog.error(DOMAIN, TAG, '%{public}s', message)
  }

  /** Last known Python version; '' until the first successful run. */
  version(): string {
    return this.pythonVersion
  }

  /**
   * A run that outlives its budget may be a Python infinite loop: the page's
   * JS queue would never drain, so every later run would sit behind it. Reload
   * the hidden page (dropping the interpreter), answer the dead request, and
   * let the next run warm Pyodide again. Correctness beats warm-start here.
   */
  private recoverExpired(): void {
    if (this.inflight.size === 0 || this.controller === null) {
      return
    }
    const now = Date.now()
    const expired: string[] = []
    this.inflight.forEach((deadline: number, name: string) => {
      if (now > deadline) {
        expired.push(name)
      }
    })
    if (expired.length === 0) {
      return
    }
    for (const name of expired) {
      const id = name.length > 9 ? name.substring(4, name.length - 5) : ''
      if (id.length > 0) {
        this.writeResult(id, JSON.stringify({
          ok: false,
          stdout: '',
          stderr: '',
          error: 'Python 运行超时，解释器已重启；请缩短代码或重试。'
        }))
      }
      this.dropRequest(name, id)
    }
    this.bridgeReady = false
    this.writeStatus(false, '', 'previous run timed out; interpreter reloaded')
    this.logEvent(`reloading runner after ${expired.length} expired run(s)`)
    hilog.warn(DOMAIN, TAG, 'reloading runner after %{public}d expired run(s)', expired.length)
    // `refresh()` did not actually re-navigate the 1×1 page on device (no
    // second page-end / bridge-ready in web.log). A new URL with a nonce makes
    // the Web component load the document again, which recreates the page and
    // its JS globals.
    try {
      this.reloadPage()
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'reload failed: %{public}s', (error as Error).message)
    }
  }

  /** The WebView render process died; a reload will recreate it on next tick. */
  onRenderExited(): void {
    this.logEvent('render process exited')
    hilog.error(DOMAIN, TAG, 'render process exited')
  }

  /** Append a line to python/web.log for post-mortem without hilog access. */
  logEvent(line: string): void {
    if (this.baseDir.length === 0) {
      return
    }
    try {
      const file = fs.openSync(`${this.baseDir}/web.log`,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND)
      fs.writeSync(file.fd, `${new Date().toISOString()} ${line}\n`)
      fs.closeSync(file.fd)
    } catch (error) {
      /* logging must never break the bridge */
    }
  }

  private ensureDirs(): void {
    if (this.baseDir.length === 0) {
      return
    }
    for (const name of ['', '/req', '/res']) {
      const dir = `${this.baseDir}${name}`
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true)
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'mkdir %{public}s failed: %{public}s', dir, (error as Error).message)
      }
    }
  }

  private tick(): void {
    if (!this.bridgeReady || this.controller === null || this.baseDir.length === 0) {
      return
    }
    this.recoverExpired()
    if (!this.bridgeReady) {
      return
    }
    let names: string[] = []
    try {
      names = fs.listFileSync(`${this.baseDir}/req`)
    } catch (error) {
      return
    }
    for (const name of names) {
      if (!name.startsWith('req-') || !name.endsWith('.json') || this.inflight.has(name)) {
        continue
      }
      const path = `${this.baseDir}/req/${name}`
      let request: PythonRequest
      try {
        request = JSON.parse(fs.readTextSync(path)) as PythonRequest
      } catch (error) {
        this.dropRequest(name, '')
        continue
      }
      if (typeof request.id !== 'string' || request.id.length === 0 ||
        typeof request.code !== 'string') {
        this.dropRequest(name, '')
        continue
      }
      const budget = Number.isFinite(request.timeoutMs) && request.timeoutMs > 0
        ? request.timeoutMs : 90000
      this.inflight.set(name, Date.now() + budget + 5000)
      this.loggedRun++
      hilog.info(DOMAIN, TAG, 'run %{public}d id=%{public}s chars=%{public}d',
        this.loggedRun, request.id, request.code.length)
      const files = Array.isArray(request.files) ? request.files : []
      const packages = Array.isArray(request.packages) ? request.packages : ['pandas']
      const script = `window.dshRun(${JSON.stringify(request.id)}, ${JSON.stringify(request.code)}, ${budget}, ` +
        `${JSON.stringify(files)}, ${JSON.stringify(packages)})`
      this.controller.runJavaScript(script).catch((error: Object) => {
        const message = (error as Error).message
        this.inflight.delete(name)
        hilog.error(DOMAIN, TAG, 'runJavaScript failed: %{public}s', message)
        this.writeResult(request.id, JSON.stringify({
          ok: false,
          stdout: '',
          stderr: '',
          error: `python bridge could not start the run: ${message}`
        }))
        this.dropRequest(name, request.id)
      })
    }
  }

  /** Write the response file before removing the request. */
  private onResult(id: string, payload: string): void {
    this.writeResult(id, payload)
    this.dropRequest(`req-${id}.json`, id)
    hilog.info(DOMAIN, TAG, 'result id=%{public}s bytes=%{public}d', id, payload.length)
  }

  private writeResult(id: string, payload: string): void {
    if (this.baseDir.length === 0) {
      return
    }
    this.atomicWrite(`${this.baseDir}/res/res-${id}.json`, payload)
  }

  private dropRequest(name: string, id: string): void {
    if (name.length > 0) {
      this.inflight.delete(name)
      try {
        fs.unlinkSync(`${this.baseDir}/req/${name}`)
      } catch (error) {
        /* already gone */
      }
    }
    if (id.length > 0) {
      this.inflight.delete(`req-${id}.json`)
    }
  }

  private writeStatus(ok: boolean, version: string, error: string): void {
    if (this.baseDir.length === 0) {
      return
    }
    const status: PythonStatus = new PythonStatus(ok, version, error, Date.now())
    this.atomicWrite(`${this.baseDir}/status.json`, JSON.stringify(status))
  }

  /** Write through a sibling temp file so a reader never sees half a JSON. */
  private atomicWrite(path: string, text: string): void {
    const temp = `${path}.tmp-${Date.now()}`
    try {
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, text)
      fs.closeSync(file.fd)
      fs.renameSync(temp, path)
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'write %{public}s failed: %{public}s', path, (error as Error).message)
      try {
        if (fs.accessSync(temp)) {
          fs.unlinkSync(temp)
        }
      } catch (_) {
        /* best effort */
      }
    }
  }
}
