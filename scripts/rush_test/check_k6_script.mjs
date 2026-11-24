#!/usr/bin/env node
// Offline self-check for load_tests/fd_championship_rush.js. No network, no k6.
//
// It loads the script against stub k6 modules under different environments and
// asserts (1) the scenario/executor shape for burst and ramp, and (2) that
// setup() refuses unsafe targets before it makes a single HTTP call.
//
//   node scripts/rush_test/check_k6_script.mjs
//
// If k6 is installed it also runs `k6 inspect` on the same script (see run below).
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'

const here = dirname(fileURLToPath(import.meta.url))
const scriptPath = resolve(here, '../../load_tests/fd_championship_rush.js')
const source = readFileSync(scriptPath, 'utf8')
const ACK = 'I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT'

const tmp = mkdtempSync(join(tmpdir(), 'rush-k6-check-'))
let failures = 0
const results = []
let networkCalls = 0

function record(name, ok, detail = '') {
  results.push({ name, ok, detail })
  if (!ok) failures += 1
}

// k6 module stubs. `fail` throws like k6's fail() aborts the run.
const stubSource = `
export const calls = { get: 0, post: 0 }
export const http = {
  get() { globalThis.__networkCalls = (globalThis.__networkCalls || 0) + 1; throw new Error('NETWORK_CALL_ATTEMPTED') },
  post() { globalThis.__networkCalls = (globalThis.__networkCalls || 0) + 1; throw new Error('NETWORK_CALL_ATTEMPTED') },
  expectedStatuses() { return () => true },
}
export function check() { return true }
export function fail(message) { throw new Error('K6_FAIL: ' + message) }
class Metric { add() {} }
export class Counter extends Metric {}
export class Rate extends Metric {}
export class Trend extends Metric {}
`
const stubPath = join(tmp, 'k6-stubs.mjs')
writeFileSync(stubPath, stubSource)
const stubUrl = pathToFileURL(stubPath).href
const patched = source
  .replace("import http from 'k6/http'", `import { http } from '${stubUrl}'`)
  .replace("import { check, fail } from 'k6'", `import { check, fail } from '${stubUrl}'`)
  .replace("import { Counter, Rate, Trend } from 'k6/metrics'", `import { Counter, Rate, Trend } from '${stubUrl}'`)
if (patched === source || patched.includes("from 'k6")) {
  console.error('Could not stub the k6 imports; the script header changed. Update this check.')
  process.exit(2)
}

let counter = 0
async function load(env) {
  counter += 1
  const file = join(tmp, `script-${counter}.mjs`)
  writeFileSync(file, patched)
  globalThis.__ENV = { ...env }
  globalThis.__VU = 1
  globalThis.__ITER = 0
  globalThis.__networkCalls = 0
  return import(`${pathToFileURL(file).href}?c=${counter}`)
}

async function expectRefusal(label, env, pattern) {
  const mod = await load(env)
  let message = ''
  try {
    mod.setup()
    message = 'setup() did not refuse'
  } catch (error) {
    message = String(error.message)
  }
  const refused = pattern.test(message) && !message.includes('NETWORK_CALL_ATTEMPTED')
  networkCalls += globalThis.__networkCalls
  record(label, refused && globalThis.__networkCalls === 0, refused ? '' : message)
}

const base = { ISOLATED_LOAD_TARGET_ACK: ACK, BASE_URL: 'https://rush-copy.onrender.com', EVENT_SLUG: 'x', TICKET_TYPE_ID: '1' }

// --- options shape ---------------------------------------------------------
{
  const { options } = await load({ ...base })
  const s = options.scenarios.free_saturation
  record('default profile is burst: per-vu-iterations, 150 VUs, 1 iteration',
    Object.keys(options.scenarios).join() === 'free_saturation' && s.executor === 'per-vu-iterations' && s.vus === 150 && s.iterations === 1,
    JSON.stringify(s))
}
{
  const { options } = await load({ ...base, SCENARIO: 'paid_holds', PROFILE: 'burst', PAID_VUS: '300', PAID_EVENT_SLUG: 'p', PAID_TICKET_TYPE_ID: '2' })
  const s = options.scenarios.paid_holds
  record('paid_holds burst honours PAID_VUS', s.executor === 'per-vu-iterations' && s.vus === 300 && s.startTime === '0s', JSON.stringify(s))
}
{
  const { options } = await load({ ...base, SCENARIO: 'free_saturation', PROFILE: 'ramp', RAMP_PEAK_RATE: '80', RAMP_UP: '20s', RAMP_HOLD: '40s' })
  const s = options.scenarios.free_saturation
  const ok = s.executor === 'ramping-arrival-rate' && s.exec === 'freeSaturation' && s.stages.length === 3 &&
    s.stages[0].target === 80 && s.stages[0].duration === '20s' && s.stages[1].duration === '40s' && s.stages[2].target === 0 &&
    s.maxVUs >= s.preAllocatedVUs
  record('free ramp: ramping-arrival-rate up to RAMP_PEAK_RATE, hold, down', ok, JSON.stringify(s))
}
{
  const { options } = await load({ ...base, SCENARIO: 'both', PROFILE: 'ramp', PAID_EVENT_SLUG: 'p', PAID_TICKET_TYPE_ID: '2' })
  const free = options.scenarios.free_saturation
  const paid = options.scenarios.paid_holds
  record('both + ramp: both ramp, paid staggered by 5s',
    free.executor === 'ramping-arrival-rate' && paid.executor === 'ramping-arrival-rate' && paid.startTime === '5s' && paid.exec === 'paidHolds',
    JSON.stringify({ free, paid }))
}
{
  const { options } = await load({ ...base, SCENARIO: 'paid_holds', PROFILE: 'ramp', PAID_EVENT_SLUG: 'p', PAID_TICKET_TYPE_ID: '2' })
  const t = options.thresholds
  record('thresholds unchanged (zero 429/5xx/unexpected 422, order p95 <= 1500, listing p95 <= 300 when free runs)',
    t.rush_throttled_429[0] === 'count==0' && t.rush_server_errors_5xx[0] === 'count==0' && t.rush_unexpected_422[0] === 'count==0' &&
      t.rush_paid_hold_latency[0] === 'p(95)<=1500' && !('rush_events_index_latency' in t),
    JSON.stringify(t))
}

// --- safety rails: refuse before any HTTP call --------------------------------
await expectRefusal('refuses without the acknowledgement', { ...base, ISOLATED_LOAD_TARGET_ACK: '' }, /ISOLATED_LOAD_TARGET_ACK/)
await expectRefusal('refuses an empty BASE_URL', { ...base, BASE_URL: '' }, /BASE_URL is required/)
await expectRefusal('refuses hafapass-api.onrender.com', { ...base, BASE_URL: 'https://hafapass-api.onrender.com' }, /production host/)
await expectRefusal('refuses userinfo trick on production host', { ...base, BASE_URL: 'https://rush-copy.onrender.com@hafapass-api.onrender.com' }, /production host/)
await expectRefusal('refuses a trailing-dot production host', { ...base, BASE_URL: 'https://hafapass-api.onrender.com./' }, /production host/)
await expectRefusal('refuses *.hafapass.com', { ...base, BASE_URL: 'https://api.hafapass.com' }, /production host/)
await expectRefusal('refuses *.shimizu-technology.com (production site/custom API domain)', { ...base, BASE_URL: 'https://hafapass.shimizu-technology.com' }, /production host/)
await expectRefusal('refuses hafapass.netlify.app', { ...base, BASE_URL: 'https://hafapass.netlify.app' }, /production host/)
await expectRefusal('refuses a host listed in HAFAPASS_PRODUCTION_HOSTS', { ...base, BASE_URL: 'https://api.example.org', HAFAPASS_PRODUCTION_HOSTS: 'api.example.org' }, /production host/)
await expectRefusal('refuses when HAFAPASS_RUSH_TARGET does not match the host', { ...base, HAFAPASS_RUSH_TARGET: 'some-other-copy.onrender.com' }, /HAFAPASS_RUSH_TARGET/)
await expectRefusal('refuses an unknown SCENARIO', { ...base, SCENARIO: 'everything' }, /SCENARIO must be/)
await expectRefusal('refuses an unknown PROFILE', { ...base, PROFILE: 'spike' }, /PROFILE must be/)

// An allowed host passes the guards and reaches the first HTTP call (the /config lookup).
{
  const mod = await load({ ...base, HAFAPASS_RUSH_TARGET: 'rush-copy.onrender.com' })
  let message = ''
  try { mod.setup() } catch (error) { message = String(error.message) }
  record('allowed isolated host + matching HAFAPASS_RUSH_TARGET gets past every guard to the /config call',
    message.includes('NETWORK_CALL_ATTEMPTED'), message)
}

// --- optional: k6 inspect ---------------------------------------------------------
const k6 = process.env.K6_BIN || 'k6'
const probe = spawnSync(k6, ['version'], { encoding: 'utf8' })
let k6Note = 'k6 not found; skipped `k6 inspect` (Node harness above still ran)'
if (probe.status === 0) {
  let inspectOk = true
  for (const profile of ['burst', 'ramp']) {
    const run = spawnSync(k6, ['inspect', '-e', `PROFILE=${profile}`, '-e', 'SCENARIO=both', '-e', 'BASE_URL=https://rush-copy.onrender.com', scriptPath], { encoding: 'utf8' })
    if (run.status !== 0) { inspectOk = false; record(`k6 inspect PROFILE=${profile}`, false, (run.stderr || run.stdout).slice(0, 400)); continue }
    const parsed = JSON.parse(run.stdout)
    const executor = parsed.scenarios.free_saturation.executor
    const expected = profile === 'ramp' ? 'ramping-arrival-rate' : 'per-vu-iterations'
    const ok = executor === expected
    inspectOk = inspectOk && ok
    record(`k6 inspect PROFILE=${profile} => ${expected}`, ok, executor)
  }
  k6Note = `${probe.stdout.trim()}: k6 inspect ${inspectOk ? 'passed' : 'FAILED'}`
}

rmSync(tmp, { recursive: true, force: true })
for (const { name, ok, detail } of results) console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok || !detail ? '' : `\n       ${detail}`}`)
console.log(`\n${k6Note}`)
console.log(`${results.length - failures}/${results.length} checks passed; network calls attempted before a guard: ${networkCalls}`)
process.exit(failures === 0 ? 0 : 1)
