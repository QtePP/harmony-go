import { common } from '@kit.AbilityKit'
import { socket } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { util } from '@kit.ArkTS'

const DOMAIN = 0xD0042
const TAG = 'PythonHttp'
const ALLOWED: Set<string> = new Set<string>([
  'runner.html',
  'pyodide-worker.js',
  'pyodide.js',
  'pyodide.asm.js',
  'pyodide.asm.wasm',
  'python_stdlib.zip',
  'pyodide-lock.json',
  'pybot.zip',
  'pyodide.mjs'
])

/**
 * Tiny loopback HTTP server for the Pyodide assets.
 *
 * `resource://rawfile` cannot serve the dynamic `import()` / `fetch()` calls
 * Pyodide makes for `pyodide.asm.js` and `pyodide.asm.wasm` (that is the exact
 * failure the first device run reported). A file:// page has the same opaque
 * origin problem. Serving the same bytes over 127.0.0.1 makes the page a normal
 * http origin, so dynamic imports and wasm fetches work without weakening the
 * WebView.
 *
 * Only the allowlisted runtime files are served, only on loopback; there is no
 * directory listing and no path from the request can escape the rawfile dir.
 */
export class PythonHttpServer {
  private server: socket.TCPSocketServer | null = null
  private context: common.UIAbilityContext
  private cache: Map<string, ArrayBuffer> = new Map<string, ArrayBuffer>()
  private port: number = 0

  constructor(context: common.UIAbilityContext) {
    this.context = context
  }

  async start(): Promise<number> {
    const server = socket.constructTCPSocketServerInstance()
    this.server = server
    server.on('connect', (connection: socket.TCPSocketConnection) => {
      this.handle(connection)
    })
    server.on('error', (error: Error) => {
      hilog.error(DOMAIN, TAG, 'server error: %{public}s', error.message)
    })
    await server.listen({ address: '127.0.0.1', port: 0, family: 1 })
    const address = await server.getLocalAddress()
    this.port = address.port ?? 0
    hilog.info(DOMAIN, TAG, 'listening on 127.0.0.1:%{public}d', this.port)
    return this.port
  }

  async stop(): Promise<void> {
    if (this.server !== null) {
      try {
        await this.server.close()
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'close failed: %{public}s', (error as Error).message)
      }
      this.server = null
    }
    this.cache.clear()
  }

  private handle(connection: socket.TCPSocketConnection): void {
    connection.on('message', (info: socket.SocketMessageInfo) => {
      const request = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(info.message))
      const line = request.split('\r\n')[0]
      const parts = line.split(' ')
      if (parts.length < 2 || parts[0] !== 'GET') {
        this.respond(connection, 400, 'text/plain', this.encode('bad request'))
        return
      }
      let path = parts[1].split('?')[0]
      if (path === '/' || path.length === 0) {
        path = '/runner.html'
      }
      const name = path.startsWith('/') ? path.slice(1) : path
      if (!ALLOWED.has(name) && !(name.endsWith('.whl') && !name.includes('/'))) {
        this.respond(connection, 404, 'text/plain', this.encode('not found'))
        return
      }
      const body = this.raw(name)
      if (body === null) {
        this.respond(connection, 404, 'text/plain', this.encode('missing'))
        return
      }
      this.respond(connection, 200, this.mime(name), body)
    })
    connection.on('close', () => {
      /* client went away; nothing to release */
    })
    connection.on('error', (error: Error) => {
      hilog.warn(DOMAIN, TAG, 'connection error: %{public}s', error.message)
    })
  }

  private raw(name: string): ArrayBuffer | null {
    const cached = this.cache.get(name)
    if (cached !== undefined) {
      return cached
    }
    try {
      const bytes = this.context.resourceManager.getRawFileContentSync(`pyodide/${name}`)
      const body = this.asArrayBuffer(bytes)
      this.cache.set(name, body)
      return body
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'rawfile %{public}s failed: %{public}s', name, (error as Error).message)
      return null
    }
  }

  private asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
  }

  private encode(text: string): ArrayBuffer {
    return this.asArrayBuffer(new util.TextEncoder().encodeInto(text))
  }

  private respond(connection: socket.TCPSocketConnection, status: number, mime: string,
    body: ArrayBuffer): void {
    const reason = status === 200 ? 'OK' : status === 404 ? 'Not Found' : 'Bad Request'
    const header = `HTTP/1.1 ${status} ${reason}\r\n` +
      `Content-Type: ${mime}\r\n` +
      `Content-Length: ${body.byteLength}\r\n` +
      `Cache-Control: max-age=3600\r\n` +
      `Connection: close\r\n\r\n`
    const head = new util.TextEncoder().encodeInto(header)
    const out = new Uint8Array(head.length + body.byteLength)
    out.set(head, 0)
    out.set(new Uint8Array(body), head.length)
    const options: socket.TCPSendOptions = { data: out.buffer as ArrayBuffer }
    connection.send(options).then(() => {
      connection.close()
    }).catch((error: Error) => {
      hilog.warn(DOMAIN, TAG, 'send failed: %{public}s', error.message)
      connection.close()
    })
  }

  private mime(name: string): string {
    if (name.endsWith('.html')) return 'text/html; charset=utf-8'
    if (name.endsWith('.js') || name.endsWith('.mjs')) return 'text/javascript; charset=utf-8'
    if (name.endsWith('.wasm')) return 'application/wasm'
    if (name.endsWith('.json')) return 'application/json'
    if (name.endsWith('.zip')) return 'application/zip'
    return 'application/octet-stream'
  }
}
