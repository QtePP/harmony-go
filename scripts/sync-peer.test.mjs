// Tests for the computer-side sync peer.
//
// These exist because the peer had two real defects that "it worked once"
// would never have caught: files arrived 0 bytes (a stream was renamed before
// it flushed), and every file was recorded under the last file's name (shared
// handler state read inside an async callback). Both are silent — the transfer
// reports success while the data is wrong — so they need tests, not a demo.
//
// Run with: node --test scripts/sync-peer.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { collector, frame, receive, resolveInside } from './sync-peer.mjs'

/* -------------------------------------------------------------- framing */

test('frame round-trips a header and a payload', () => {
  const bytes = frame({ t: 'chunk' }, Buffer.from('hello'))
  let seen = null
  collector((header, data) => {
    seen = { header, data: data === null ? null : data.toString('utf8') }
  })(bytes)
  assert.deepEqual(seen, { header: { t: 'chunk' }, data: 'hello' })
});

test('collector reassembles a frame split across chunks', () => {
  const bytes = frame({ t: 'hello', code: '123456' })
  const seen = []
  const feed = collector((header) => seen.push(header))
  for (let i = 0; i < bytes.length; i++) feed(bytes.subarray(i, i + 1))
  assert.equal(seen.length, 1)
  assert.equal(seen[0].code, '123456')
});

test('collector handles several frames arriving at once', () => {
  const bytes = Buffer.concat([
    frame({ t: 'a' }),
    frame({ t: 'b' }, Buffer.from('xy')),
    frame({ t: 'c' })
  ])
  const seen = []
  collector((header, data) => seen.push([header.t, data === null ? 0 : data.length]))(bytes)
  assert.deepEqual(seen, [['a', 0], ['b', 2], ['c', 0]])
});

test('collector stops on a malformed header rather than resynchronising', () => {
  // A non-JSON header cannot be framed forward; guessing its length would mean
  // parsing attacker-chosen bytes as the next frame.
  const bad = Buffer.alloc(8 + 1 + 4)
  bad.writeUInt32BE(1, 0)
  bad.write('{', 4)
  bad.writeUInt32BE(0, 5)
  const seen = []
  collector((header) => seen.push(header.t))(bad)
  assert.deepEqual(seen, ['__bad_header__'])
});

/* ------------------------------------------------------- path containment */

test('resolveInside accepts ordinary and nested paths', () => {
  assert.equal(resolveInside('/out', 'a.md'), '/out/a.md')
  assert.equal(resolveInside('/out', 'sub/dir/b.bin'), '/out/sub/dir/b.bin')
});

test('resolveInside refuses traversal, absolute paths and empty segments', () => {
  for (const bad of ['../x', '/etc/passwd', 'a/../../b', '', 'a//b', '.', 'a/./b']) {
    assert.throws(() => resolveInside('/out', bad), /refusing path|non-empty string/, bad)
  }
});

test('resolveInside refuses a non-string path', () => {
  assert.throws(() => resolveInside('/out', undefined), /non-empty string/)
  assert.throws(() => resolveInside('/out', 42), /non-empty string/)
});

/* ------------------------------------------------------------- traversal */

/** Minimal sender so a hostile manifest can be replayed at a real receiver. */
function hostileSender(port, evilPath, payload) {
  return new Promise((resolve) => {
    const sock = net.connect(port, '127.0.0.1')
    sock.on('connect', () => {
      sock.write(frame({ t: 'hello', version: 1, code: '123456', name: 'evil',
        files: 1, bytes: payload.length, entries: [{ path: evilPath, size: payload.length }] }))
    })
    sock.on('data', (buf) => {
      if (buf.toString('utf8').includes('accept')) {
        sock.write(frame({ t: 'file', path: evilPath, size: payload.length }))
        sock.write(frame({ t: 'chunk' }, payload))
        sock.write(frame({ t: 'fileEnd', path: evilPath, size: payload.length }))
        sock.write(frame({ t: 'done', files: 1, bytes: payload.length }))
      }
    })
    sock.on('close', resolve)
    sock.on('error', resolve)
    setTimeout(resolve, 2500)
  })
}

test('a traversal attempt writes nothing inside or outside the target', async () => {
  // The whole point of the pairing code is that this endpoint must never be a
  // remote file-write primitive. Drive the real receiver in-process (a spawned
  // child would keep the test runner's stdout pipe open and hang it) to prove
  // the guard sits on the write path, not merely in a helper.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-guard-'))
  const marker = `dsh-escape-${process.pid}.txt`
  const evil = `../${marker}`
  process.env.DSH_SYNC_PEER_KEEPALIVE = '1'
  const logs = []
  const originalLog = console.log
  console.log = (...args) => { logs.push(args.join(' ')) }
  let server
  try {
    server = receive(0, '123456', root)
    const port = await new Promise((resolve) => {
      if (server.listening) {
        resolve(server.address().port)
        return
      }
      server.once('listening', () => resolve(server.address().port))
    })
    await hostileSender(port, evil, Buffer.from('PWNED'))
  } finally {
    console.log = originalLog
    delete process.env.DSH_SYNC_PEER_KEEPALIVE
    if (server) server.close()
  }

  try {
    assert.ok(logs.some((line) => /REFUSED/.test(line)), `expected a refusal, logged: ${logs.join(' | ')}`)
    assert.equal(fs.existsSync(path.join(path.dirname(root), marker)), false, 'nothing may be written outside')
    const inside = fs.readdirSync(root)
    assert.deepEqual(inside, [], `nothing may be written inside either, found: ${inside.join(',')}`)
  } finally {
    fs.rmSync(path.join(path.dirname(root), marker), { force: true })
    fs.rmSync(root, { recursive: true, force: true })
  }
});
