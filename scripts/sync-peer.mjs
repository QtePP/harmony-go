#!/usr/bin/env node
// Computer-side peer for the HarmonyGo project-sync protocol.
//
//   node scripts/sync-peer.mjs receive <port> <code> <outDir>
//   node scripts/sync-peer.mjs send <host:port> <code> <srcDir> [name]
//   node scripts/sync-peer.mjs watch               # print what a device would see
//
// The wire format lives in entry/src/main/ets/common/ProjectSync.ets, and this
// file mirrors its safety rules rather than trusting the sender:
//
//   - a path is rejected if any segment is `..` or empty (the device's
//     resolveInside does the same), so a hostile manifest cannot write outside
//     <outDir>;
//   - the whole tree is assembled under a staging directory and moved into
//     place only after every file arrived and matched its declared size, so a
//     cancelled or truncated transfer leaves the target untouched;
//   - an existing path is skipped and reported, never overwritten — v1 trades
//     conflict merging for determinism, and overwriting someone's file on a
//     pairing-code handshake is not a trade worth making.
//
// Deliberately dependency-free: this must run on a Mac with nothing installed.
import net from 'node:net'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const CHUNK = 32 * 1024
/** Per-file cap, matching the device's MAX_FILE_BYTES. */
const MAX_FILE_BYTES = 64 * 1024 * 1024
const SKIP_DIRS = ['.git', 'node_modules', '.hvigor', '.build']

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
      let header
      try {
        header = JSON.parse(buf.subarray(4, 4 + hlen).toString('utf8'))
      } catch (error) {
        // A malformed header cannot be framed forward; drop the connection
        // rather than resynchronise on attacker-chosen bytes.
        onFrame({ t: '__bad_header__' }, null)
        return
      }
      const dlen = buf.readUInt32BE(4 + hlen)
      const total = 8 + hlen + dlen
      if (buf.length < total) return
      const data = dlen ? buf.subarray(8 + hlen, total) : null
      buf = buf.subarray(total)
      onFrame(header, data)
    }
  }
}

/**
 * Join `root` and a manifest-relative path without trusting it.
 *
 * Mirrors resolveInside on the device: reject `..` and empty segments. The
 * extra `startsWith` check catches anything the segment walk missed (an
 * absolute path, a Windows drive letter).
 */
function resolveInside(root, relative) {
  if (typeof relative !== 'string' || relative.length === 0) {
    throw new Error('manifest path must be a non-empty string')
  }
  const parts = relative.split('/')
  for (const part of parts) {
    // `.` resolves to the directory itself: a manifest entry that names no
    // file is as wrong as one that climbs out.
    if (part === '..' || part === '.' || part.length === 0) {
      throw new Error(`refusing path with "..", "." or an empty segment: ${relative}`)
    }
  }
  const target = path.resolve(root, relative)
  const rootResolved = path.resolve(root)
  if (target !== rootResolved && !target.startsWith(rootResolved + path.sep)) {
    throw new Error(`path escapes the target directory: ${relative}`)
  }
  return target
}

function walk(root, dir = '', out = []) {
  for (const name of fs.readdirSync(path.join(root, dir))) {
    if (SKIP_DIRS.includes(name)) continue
    const rel = dir ? `${dir}/${name}` : name
    const st = fs.statSync(path.join(root, rel))
    if (st.isDirectory()) {
      walk(root, rel, out)
    } else if (st.size > MAX_FILE_BYTES) {
      console.log(`skip (over ${MAX_FILE_BYTES / 1024 / 1024}MB):`, rel)
    } else {
      out.push({ path: rel, size: st.size })
    }
  }
  return out
}

function rmTree(target) {
  fs.rmSync(target, { recursive: true, force: true })
}

function megabytes(bytes) {
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

/* ------------------------------------------------------------------ receive */

function receive(port, code, outDir) {
  const root = path.resolve(outDir)
  fs.mkdirSync(root, { recursive: true })
  const staging = path.join(os.tmpdir(), `harmonygo-sync-${process.pid}`)
  rmTree(staging)
  fs.mkdirSync(staging, { recursive: true })

  let current = null
  let currentRel = ''
  let written = 0
  let declared = 0
  const received = []
  const skipped = []
  /** Promises of in-flight file closes; committed only when all settle. */
  const pending = []
  let bytes = 0
  let failed = false

  /** Move every staged file into place, refusing to overwrite. */
  function commit() {
    for (const entry of received) {
      const from = resolveInside(staging, entry.path)
      const to = resolveInside(root, entry.path)
      if (fs.existsSync(to)) {
        skipped.push(entry.path)
        continue
      }
      fs.mkdirSync(path.dirname(to), { recursive: true })
      fs.renameSync(from, to)
    }
  }

  const server = net.createServer((sock) => {
    console.log('connection from', sock.remoteAddress)
    let cleared = false

    const finish = (reason) => {
      if (cleared) return
      cleared = true
      try { sock.destroy() } catch (_) {}
      try { server.close() } catch (_) {}
      rmTree(staging)
      if (reason) console.log('aborted:', reason)
    }

    sock.on('error', (error) => finish(error.message))
    sock.on('data', collector((header, data) => {
      if (header.t === '__bad_header__') {
        failed = true
        finish('malformed header')
        return
      }
      if (header.t === 'hello') {
        if (header.code !== code) {
          console.log('DENIED wrong code')
          sock.write(frame({ t: 'deny', reason: '配对码不对' }))
          failed = true
          finish('wrong pairing code')
          return
        }
        console.log(`hello ${header.name} · ${header.files} files · ${megabytes(header.bytes || 0)}`)
        sock.write(frame({ t: 'accept' }))
        return
      }
      if (header.t === 'sessions') {
        // Written next to the project, not into it: the device sends its
        // session index and transcript bundle as one opaque payload, and a
        // manifest entry may not have covered it. Anchored to `root` so a
        // relative outDir cannot land the file somewhere else.
        const text = data ? data.toString('utf8') : ''
        const target = path.join(root, '.sessions.json')
        fs.writeFileSync(target, text)
        console.log(`sessions frame ${text.length} bytes -> ${target}`)
        return
      }
      if (header.t === 'file') {
        if (current) {
          failed = true
          finish('file boundary crossed before fileEnd')
          return
        }
        try {
          resolveInside(root, header.path)
          currentRel = header.path
        } catch (error) {
          console.log('REFUSED', error.message)
          sock.write(frame({ t: 'error', reason: error.message }))
          failed = true
          finish(error.message)
          return
        }
        const target = resolveInside(staging, currentRel)
        fs.mkdirSync(path.dirname(target), { recursive: true })
        current = fs.createWriteStream(target)
        written = 0
        declared = header.size
        return
      }
      if (header.t === 'chunk') {
        if (!current || !data) {
          failed = true
          finish('chunk without a file')
          return
        }
        current.write(data)
        written += data.length
        bytes += data.length
        return
      }
      if (header.t === 'fileEnd') {
        if (!current) return
        // end() is asynchronous: the buffered writes land after this call, so
        // commit() must wait for the close. Skipping that await is how every
        // received file ended up 0 bytes — rename moved the inode before the
        // stream had flushed.
        const stream = current
        current = null
        // Capture the per-file values now. `currentRel` and `declared` are
        // shared handlers' state: reading them inside the async callback read
        // whichever file arrived next, which is how three different files were
        // all recorded as the last one.
        const rel = currentRel
        const size = declared
        const got = written
        const closed = new Promise((resolve) => stream.end(resolve))
        if (got !== size) {
          console.log(`SIZE MISMATCH ${rel} ${got}/${size}`)
          failed = true
          finish('size mismatch')
          return
        }
        pending.push(closed.then(() => {
          const staged = resolveInside(staging, rel)
          const onDisk = fs.existsSync(staged) ? fs.statSync(staged).size : -1
          if (onDisk !== size) {
            throw new Error(`${rel}: staged ${onDisk} bytes, declared ${size}`)
          }
          received.push({ path: rel })
          console.log('file', rel, 'OK')
        }))
        return
      }
      if (header.t === 'done') {
        if (failed) return
        // Wait for every file to close *and* re-check its size on disk before
        // the rename: a stream that lost data must fail loudly, not install a
        // truncated file.
        Promise.all(pending).then(() => {
          commit()
          return finish(null)
        }).catch((error) => {
          failed = true
          console.log('REFUSED', error.message)
          finish(error.message)
        }).then(() => {
          if (!failed) {
            console.log(`DONE files=${received.length} bytes=${bytes}`)
            if (skipped.length > 0) {
              console.log(`skipped ${skipped.length} existing path(s):`)
              for (const one of skipped) console.log('  -', one)
            }
            // In-process callers (tests, embedding) set this to stay alive.
            if (!process.env.DSH_SYNC_PEER_KEEPALIVE) {
              process.exit(0)
            }
          }
        })
        return
      }
      if (header.t === 'done_legacy') {
        if (failed) return
        commit()
        console.log(`DONE files=${received.length} bytes=${bytes}`)
        if (skipped.length > 0) {
          console.log(`skipped ${skipped.length} existing path(s):`)
          for (const one of skipped) console.log('  -', one)
        }
        finish(null)
        process.exit(0)
      }
      if (header.t === 'error') {
        console.log('peer error', header.reason)
        failed = true
        finish(header.reason)
        process.exit(1)
      }
    }))
    sock.on('close', () => {
      // Closing without `done` means the sender gave up: staging is dropped and
      // the target keeps whatever it had.
      if (!failed && received.length > 0) {
        console.log('connection closed before done — nothing written')
      }
      rmTree(staging)
    })
  })
  server.listen(Number(port), '0.0.0.0', () => {
    console.log(`receiving on :${port} · code ${code} · into ${root}`)
    console.log('point the device at this Mac\'s LAN address, then Send')
  })
  return server
}

/* --------------------------------------------------------------------- send */

function send(addr, code, srcDir, name, sessionsFile) {
  const [host, portText] = addr.split(':')
  const port = Number(portText || 4519)
  const entries = walk(srcDir)
  const total = entries.reduce((sum, e) => sum + e.size, 0)
  console.log(`sending ${entries.length} files · ${megabytes(total)} to ${host}:${port}`)

  const sock = net.connect(port, host)
  let state = 'hello'

  sock.on('connect', () => {
    sock.write(frame({
      t: 'hello',
      version: 1,
      code,
      name: name || os.hostname(),
      files: entries.length,
      bytes: total,
      entries
    }))
  })
  sock.on('error', (error) => {
    console.error('connection failed:', error.message)
    process.exit(1)
  })
  sock.on('close', () => {
    if (state !== 'done') {
      console.error('closed before the transfer finished')
      process.exit(1)
    }
  })
  sock.on('data', collector((header) => {
    if (header.t === 'deny') {
      console.error('DENIED:', header.reason)
      process.exit(1)
    }
    if (header.t === 'error') {
      console.error('peer error:', header.reason)
      process.exit(1)
    }
    if (header.t !== 'accept' || state !== 'hello') return
    state = 'streaming'
    if (sessionsFile) {
      const blob = fs.readFileSync(sessionsFile)
      sock.write(frame({ t: 'sessions' }, blob))
      console.log('sessions frame sent', blob.length, 'bytes')
    }
    let sent = 0
    for (const entry of entries) {
      sock.write(frame({ t: 'file', path: entry.path, size: entry.size }))
      const fd = fs.openSync(path.join(srcDir, entry.path), 'r')
      const buf = Buffer.alloc(CHUNK)
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
      console.log('sent', entry.path)
    }
    sock.write(frame({ t: 'done', files: entries.length, bytes: sent }))
    state = 'done'
    console.log(`DONE files=${entries.length} bytes=${sent}`)
    setTimeout(() => process.exit(0), 300)
  }))
}

/* -------------------------------------------------------------------- watch */

/** Print the manifest a device would build for a directory, without sending. */
function watch(dir) {
  const root = path.resolve(dir || '.')
  const entries = walk(root)
  const total = entries.reduce((sum, e) => sum + e.size, 0)
  console.log(`would send ${entries.length} files · ${megabytes(total)} from ${root}`)
  for (const entry of entries) console.log(' ', entry.path, megabytes(entry.size))
}

/** Only run the CLI when executed directly; importing must stay side-effect free. */
function main() {
if (mode === 'receive') {
  const [port, code, outDir] = rest
  if (!port || !code || !outDir) {
    console.error('usage: receive <port> <code> <outDir>')
    process.exit(2)
  }
  receive(port, code, outDir)
} else if (mode === 'send') {
  const [addr, code, srcDir, name, sessionsFile] = rest
  if (!addr || !code || !srcDir) {
    console.error('usage: send <host:port> <code> <srcDir> [name] [sessions.json]')
    process.exit(2)
  }
  send(addr, code, srcDir, name, sessionsFile)
} else if (mode === 'watch') {
  watch(rest[0])
} else {
  console.error('usage: receive <port> <code> <outDir> | send <host:port> <code> <srcDir> [name] [sessions.json] | watch [dir]')
  process.exit(2)
}
}

// argv[1] ends with this file when run as a script; importing it from a test
// must not start a server or exit the process.
const invokedDirectly = process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)
if (invokedDirectly) {
  main()
}

export { resolveInside, frame, collector, walk, main, receive, send }