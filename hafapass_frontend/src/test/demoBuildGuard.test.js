import process from 'node:process'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, vi } from 'vitest'
for (const context of ['production', '', 'branch-deploy']) {
  it(`refuses a demo build in ${context || 'an ordinary production build'}`, () => {
    let output = ''
    try {
      execFileSync(process.execPath, ['node_modules/vite/bin/vite.js', 'build'], { cwd: process.cwd(), env: { ...process.env, CONTEXT: context, VITE_HAFAPASS_DEMO_DATA: '1' }, stdio: 'pipe' })
    } catch (error) { output = String(error.stderr) }
    expect(output).toContain('Demo data can only be built in the deploy-preview context; production is forbidden')
  })
}

// A flag-off production build must not contain the demo layer: no fixtures, no
// handler registry, no demo staff identity. Each string below is distinctive
// text from a demo file; add one when you add a fixture file (src/demo/README.md).
const DEMO_STRINGS = [
  'HAFAPASS_DEMO_FIXTURE_SENTINEL', 'HAFAPASS_DEMO_STAFF_SENTINEL', 'HAFAPASS_DEMO_PAYOUT_SENTINEL', 'Isla Demo Sports League', 'demo_staff_user',
  'demo-staff-token', '[demo-api]', 'Demo preview · fictional data', 'x-hafapass-demo', 'Copa de Marianas 2027 (demo)',
]

function listFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => (
    entry.isDirectory() ? listFiles(join(directory, entry.name)) : [join(directory, entry.name)]
  ))
}

// A `null` value removes the variable, matching Netlify production where the
// demo flag is not set at all.
function buildEnv(overrides) {
  const env = { ...process.env }
  for (const [key, value] of Object.entries(overrides)) {
    if (value === null) delete env[key]
    else env[key] = value
  }
  return env
}

function buildFound(env) {
  const outDir = mkdtempSync(join(tmpdir(), 'hafapass-build-'))
  try {
    execFileSync(process.execPath, ['node_modules/vite/bin/vite.js', 'build', '--outDir', outDir, '--emptyOutDir'], {
      cwd: process.cwd(), env: buildEnv(env), stdio: 'pipe',
    })
    const found = []
    for (const file of listFiles(outDir).filter(name => /\.(js|css|html|json|map|webmanifest)$/.test(name))) {
      const text = readFileSync(file, 'utf8')
      for (const needle of DEMO_STRINGS) if (text.includes(needle)) found.push(`${needle} in ${file.slice(outDir.length)}`)
    }
    return found
  } finally {
    rmSync(outDir, { recursive: true, force: true })
  }
}

it('the string scan is not vacuous: a deploy-preview demo build does contain the demo layer', () => {
  const found = buildFound({ CONTEXT: 'deploy-preview', VITE_HAFAPASS_DEMO_DATA: '1' }).join('\n')
  for (const needle of ['HAFAPASS_DEMO_STAFF_SENTINEL', 'HAFAPASS_DEMO_PAYOUT_SENTINEL', 'Isla Demo Sports League', 'demo_staff_user']) expect(found).toContain(needle)
}, 240_000)

it('ships no demo layer, handler or staff fixture in a production build, and keeps the demo staff identity off', () => {
  expect(buildFound({ CONTEXT: 'production', VITE_HAFAPASS_DEMO_DATA: null })).toEqual([])
}, 240_000)

it('does not install or honor the demo staff identity with the flag off', async () => {
  vi.resetModules()
  vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '')
  const client = await import('../api/client')
  expect(client.getApiAuthContext()).toBeNull()
  expect(typeof client.default.defaults.adapter).not.toBe('function')
  const { isDemoDataEnabled } = await import('../utils/demoMode')
  expect(isDemoDataEnabled()).toBe(false)
  vi.unstubAllEnvs()
})
