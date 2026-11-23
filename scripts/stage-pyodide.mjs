#!/usr/bin/env node
/**
 * Stage the offline Pyodide runtime into the HAP rawfile.
 *
 * The 5.3 MB npm tarball is vendored (`host/pyodide/pyodide-0.29.0.tgz`) so a
 * build never depends on the network or on a floating version. This script
 * expands it into `entry/src/main/resources/rawfile/pyodide/` (gitignored)
 * and adds the runner page. Run it before `devecocli build` / `deploy.sh`
 * whenever the rawfile directory is missing or the tarball changed.
 *
 * Usage: node scripts/stage-pyodide.mjs [--force]
 */

import { execFileSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const TARBALL = join(ROOT, 'host', 'pyodide', 'pyodide-0.29.0.tgz')
const RUNNER = join(ROOT, 'host', 'pyodide', 'runner.html')
const WORKER = join(ROOT, 'host', 'pyodide', 'pyodide-worker.js')
const PACKAGES = join(ROOT, 'host', 'pyodide', 'packages')
const PYBOT = join(ROOT, 'host', 'pybot', 'pybot.zip')
const OUTPUT = join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'pyodide')
const STAMP = join(OUTPUT, '.stamp')
const VERSION = '0.29.0'
const KEEP = new Set([
  'pyodide.js',
  'pyodide.asm.js',
  'pyodide.asm.wasm',
  'python_stdlib.zip',
  'pyodide-lock.json',
  'pyodide.mjs'
])

const force = process.argv.includes('--force')

if (!existsSync(TARBALL)) {
  console.error(`missing vendored tarball: ${TARBALL}`)
  process.exit(1)
}
if (!existsSync(RUNNER)) {
  console.error(`missing runner page: ${RUNNER}`)
  process.exit(1)
}
if (!force && existsSync(STAMP) && readFileSync(STAMP, 'utf8').trim() === VERSION) {
  console.log(`pyodide ${VERSION} already staged at ${OUTPUT}`)
  process.exit(0)
}

const work = join(ROOT, '.build', 'pyodide-extract')
rmSync(work, { recursive: true, force: true })
mkdirSync(work, { recursive: true })
execFileSync('tar', ['-xzf', TARBALL, '-C', work], { stdio: 'inherit' })

rmSync(OUTPUT, { recursive: true, force: true })
mkdirSync(OUTPUT, { recursive: true })
const pkg = join(work, 'package')
for (const name of readdirSync(pkg)) {
  if (!KEEP.has(name)) continue
  cpSync(join(pkg, name), join(OUTPUT, name))
}
cpSync(RUNNER, join(OUTPUT, 'runner.html'))
cpSync(WORKER, join(OUTPUT, 'pyodide-worker.js'))
if (existsSync(PYBOT)) {
  cpSync(PYBOT, join(OUTPUT, 'pybot.zip'))
}
if (existsSync(PACKAGES)) {
  for (const name of readdirSync(PACKAGES)) {
    if (!name.endsWith('.whl')) continue
    cpSync(join(PACKAGES, name), join(OUTPUT, name))
  }
}
writeFileSync(STAMP, `${VERSION}\n`)

let bytes = 0
for (const name of readdirSync(OUTPUT)) {
  const path = join(OUTPUT, name)
  try {
    bytes += readFileSync(path).length
  } catch (_) {
    /* a directory (none expected) */
  }
}
console.log(`pyodide ${VERSION} staged at ${OUTPUT} (${(bytes / 1024 / 1024).toFixed(1)} MiB)`)
