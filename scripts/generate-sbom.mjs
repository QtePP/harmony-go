#!/usr/bin/env node
/**
 * Generate a CycloneDX SBOM for the assembled dsh payload.
 *
 * The payload is the only place the app's third-party surface is complete:
 * 676 installed packages (642 unique name@version) under
 * `.build/payload/node_modules`, with `.build/payload/package-lock.json` as the
 * resolved inventory. The SBOM records name, version, license and the registry
 * tarball URL; it does not re-hash 240 MB of files, because the lockfile's
 * integrity field is the artifact digest the installer already verified.
 *
 * Usage:
 *   node scripts/generate-sbom.mjs
 *   node scripts/generate-sbom.mjs --out dist/sbom.cdx.json --lock .build/payload/package-lock.json
 *
 * Run `scripts/assemble-payload.mjs` first. The output is a release asset; it is
 * not committed (the lockfile is generated too).
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 && process.argv[index + 1] !== undefined ? process.argv[index + 1] : fallback
}

const LOCK = resolve(ROOT, arg('lock', '.build/payload/package-lock.json'))
const OUT = resolve(ROOT, arg('out', '.build/sbom.cdx.json'))

function appVersion() {
  try {
    const text = readFileSync(resolve(ROOT, 'AppScope/app.json5'), 'utf8')
    const match = text.match(/"versionName"\s*:\s*"([^"]+)"/)
    return match === null ? '0.0.0' : match[1]
  } catch {
    return '0.0.0'
  }
}

/** SPDX expression or a free-form license name. */
function licenseOf(raw) {
  if (typeof raw === 'string' && raw.trim().length > 0) return { id: raw.trim() }
  if (raw !== null && typeof raw === 'object') {
    const value = Array.isArray(raw) ? raw.map((part) => part?.type ?? part).join(' OR ') : raw.type
    if (typeof value === 'string' && value.trim().length > 0) return { id: value.trim() }
  }
  return undefined
}

/** Lockfile key → package name (`node_modules/@scope/pkg` → `@scope/pkg`). */
function nameOf(key) {
  const marker = 'node_modules/'
  const at = key.lastIndexOf(marker)
  return at < 0 ? key : key.slice(at + marker.length)
}

/** npm purl; the scope separator is percent-encoded per the purl spec. */
function purlOf(name, version) {
  const encoded = name.startsWith('@') ? `%40${name.slice(1)}` : name
  return `pkg:npm/${encoded}@${version}`
}

/** SRI (`sha512-<base64>`) → CycloneDX hash. */
function hashOf(integrity) {
  if (typeof integrity !== 'string') return undefined
  const dash = integrity.indexOf('-')
  const algorithm = integrity.slice(0, dash)
  const base64 = integrity.slice(dash + 1)
  const names = { sha512: 'SHA-512', sha384: 'SHA-384', sha256: 'SHA-256', sha1: 'SHA-1' }
  const alg = names[algorithm]
  if (alg === undefined || base64.length === 0) return undefined
  try {
    return { alg, content: Buffer.from(base64, 'base64').toString('hex') }
  } catch {
    return undefined
  }
}

/** Installed identity set: the lockfile also lists optional packages that were pruned. */
function installedIdentities(root) {
  const out = new Set()
  const walk = (dir) => {
    let entries = []
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name === '.bin') continue
      const child = resolve(dir, entry.name)
      if (entry.name.startsWith('@')) {
        walk(child)
        continue
      }
      const manifest = resolve(child, 'package.json')
      if (existsSync(manifest)) {
        try {
          const pkg = JSON.parse(readFileSync(manifest, 'utf8'))
          if (typeof pkg.name === 'string' && typeof pkg.version === 'string') {
            out.add(`${pkg.name}@${pkg.version}`)
          }
        } catch {
          /* a malformed package is still not a reason to fail the SBOM */
        }
      }
      walk(resolve(child, 'node_modules'))
    }
  }
  walk(root)
  return out
}

const MODULES = resolve(ROOT, arg('modules', '.build/payload/node_modules'))
if (!existsSync(MODULES)) {
  throw new Error(`payload not assembled: ${MODULES} (run scripts/assemble-payload.mjs first)`)
}
const installed = installedIdentities(MODULES)

const lock = JSON.parse(readFileSync(LOCK, 'utf8'))
const packages = lock.packages ?? {}
const seen = new Set()
const components = []

for (const [key, entry] of Object.entries(packages)) {
  if (key.length === 0 || !key.includes('node_modules/') || typeof entry.version !== 'string') continue
  const name = nameOf(key)
  const identity = `${name}@${entry.version}`
  if (seen.has(identity) || !installed.has(identity)) continue
  seen.add(identity)

  const component = {
    type: 'library',
    name,
    version: entry.version,
    'bom-ref': purlOf(name, entry.version),
    purl: purlOf(name, entry.version)
  }
  const license = licenseOf(entry.license)
  if (license !== undefined) component.licenses = [{ license }]
  const hash = hashOf(entry.integrity)
  if (hash !== undefined) component.hashes = [hash]
  if (typeof entry.resolved === 'string') {
    component.externalReferences = [{ type: 'distribution', url: entry.resolved }]
  }
  components.push(component)
}

components.sort((a, b) => a['bom-ref'].localeCompare(b['bom-ref']))

const bom = {
  bomFormat: 'CycloneDX',
  specVersion: '1.5',
  serialNumber: `urn:uuid:${randomUUID()}`,
  version: 1,
  metadata: {
    timestamp: new Date().toISOString(),
    tools: [{ vendor: 'HarmonyGo', name: 'generate-sbom.mjs', version: '1' }],
    component: {
      type: 'application',
      name: 'harmony-go',
      version: appVersion(),
      purl: `pkg:generic/harmony-go@${appVersion()}`
    }
  },
  components
}

mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, `${JSON.stringify(bom, null, 2)}\n`, 'utf8')
console.log(`sbom: ${components.length} components → ${OUT}`)
