#!/usr/bin/env node
// Test peer for the HarmonyGo project-sync protocol (Projectsync.ets).
//   node sync-peer.mjs receive <port> <code> <outDir>
//   node sync-peer.mjs send <host:port> <code> <srcDir> <name>
import net from 'node:net'
import fs from 'node:fs'
import path from 'node:path'

const [, , mode, ...rest] = process.argv

function frame(header, data) {
  const json = Buffer.from(JSON.stringify(header), 'utf8')
  const head = Buffer.alloc(4)
  head.writeUInt32BE(json.length, 0)
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data ? data.length : 0, 0)
  return Buffer.concat([head, json, len, data || Buffer.alloc(0)])
}

function collector(onFrame) {
  let buf = Buffer.alloc(0)
  return (chunk) => {
    buf = Buffer.concat([buf, chunk])
    for (;;) {
      if (buf.length < 8) return
      const hlen = buf.readUInt32BE(0)
      if (buf.length < 4 + hlen + 4) return
      const header = JSON.parse(buf.subarray(4, 4 + hlen).toString('utf8'))
      const dlen = buf.readUInt32BE(4 + hlen)
      const total = 8 + hlen + dlen
      if (buf.length < total) return
      const data = dlen ? buf.subarray(8 + hlen, total) : null
      buf = buf.subarray(total)
      onFrame(header, data)
    }
  }
}

function walk(root, dir = '', out = []) {
  for (const name of fs.readdirSync(path.join(root, dir))) {
    if (['.git', 'node_modules', '.hvigor', '.build'].includes(name)) continue
    const rel = dir ? `${dir}/${name}` : name
    const st = fs.statSync(path.join(root, rel))
    if (st.isDirectory()) walk(root, rel, out)
    else out.push({ path: rel, size: st.size })
  }
  return out
}

if (mode === 'receive') {
  const [port, code, outDir] = rest
  if (!port || !code || !outDir) {
    console.error('usage: receive <port> <code> <outDir>')
    process.exit(2)
  }
  fs.mkdirSync(outDir, { recursive: true })
  let current = null
  let currentWritten = 0
  let currentSize = 0
  let files = 0
  let bytes = 0
  const server = net.createServer((sock) => {
    console.log('connection from', sock.remoteAddress)
    sock.on('data', collector((header, data) => {
      if (header.t === 'hello') {
        if (header.code !== code) {
          console.log('DENIED wrong code', header.code)
          sock.write(frame({ t: 'deny', reason: '配对码不对' }))
          return
        }
        console.log('hello', header.name, 'files', header.files, 'bytes', header.bytes)
        sock.write(frame({ t: 'accept' }))
        return
      }
      if (header.t === 'file') {
        if (current) current.end()
        const target = path.join(outDir, header.path)
        fs.mkdirSync(path.dirname(target), { recursive: true })
        current = fs.createWriteStream(target)
        currentWritten = 0
        currentSize = header.size
        return
      }
      if (header.t === 'chunk') {
        if (!current || !data) throw new Error('chunk without file')
        current.write(data)
        currentWritten += data.length
        bytes += data.length
        return
      }
      if (header.t === 'fileEnd') {
        current.end()
        current = null
        files++
        console.log('file', header.path, currentWritten === currentSize ? 'OK' : `SIZE MISMATCH ${currentWritten}/${currentSize}`)
        return
      }
      if (header.t === 'done') {
        console.log(`DONE files=${files} bytes=${bytes}`)
        sock.end()
        server.close()
        process.exit(0)
      }
      if (header.t === 'error') {
        console.log('peer error', header.reason)
        process.exit(1)
      }
    }))
  })
  server.listen(Number(port), '0.0.0.0', () => {
    console.log(`receiving on :${port}, code ${code}, out ${outDir}`)
  })
} else if (mode === 'send') {
  const [addr, code, srcDir, name] = rest
  if (!addr || !code || !srcDir) {
    console.error('usage: send <host:port> <code> <srcDir> [name]')
    process.exit(2)
  }
  const [host, portText] = addr.split(':')
  const entries = walk(srcDir)
  const total = entries.reduce((sum, e) => sum + e.size, 0)
  const sock = net.connect(Number(portText || 4519), host)
  let state = 'hello'
  sock.on('connect', () => {
    sock.write(frame({
      t: 'hello', version: 1, code, name: name || 'mac',
      files: entries.length, bytes: total, entries
    }))
  })
  sock.on('data', collector(async (header) => {
    if (header.t === 'deny') {
      console.log('DENIED', header.reason)
      process.exit(1)
    }
    if (header.t !== 'accept' || state !== 'hello') return
    state = 'streaming'
    let sent = 0
    let files = 0
    for (const entry of entries) {
      const full = path.join(srcDir, entry.path)
      sock.write(frame({ t: 'file', path: entry.path, size: entry.size }))
      const fd = fs.openSync(full, 'r')
      const buf = Buffer.alloc(32 * 1024)
      let offset = 0
      while (offset < entry.size) {
        const n = fs.readSync(fd, buf, 0, Math.min(buf.length, entry.size - offset), offset)
        if (n <= 0) break
        sock.write(frame({ t: 'chunk' }, Buffer.from(buf.subarray(0, n))))
        offset += n
        sent += n
      }
      fs.closeSync(fd)
      sock.write(frame({ t: 'fileEnd', path: entry.path, size: entry.size }))
      files++
      console.log('sent', entry.path)
    }
    sock.write(frame({ t: 'done', files, bytes: sent }))
    console.log(`DONE files=${files} bytes=${sent}`)
    setTimeout(() => process.exit(0), 300)
  }))
  sock.on('close', () => {})
} else {
  console.error('usage: receive|send ...')
  process.exit(2)
}
