import crypto from 'node:crypto'
import process from 'node:process'
import { execFileSync, spawn } from 'node:child_process'
import { once } from 'node:events'
import { readFileSync, rmSync } from 'node:fs'
import { expect, test } from '@playwright/test'

const A = 'a'.repeat(40)
const B = 'b'.repeat(40)
const C = 'c'.repeat(40)
const origin = 'http://127.0.0.1:5234'
let apiFixtures = {}
function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function signedManifest(tickets) {
  const event = { id: 42, title: 'Guam Night Market', status: 'published', venue_name: 'Chamorro Village', starts_at: new Date(Date.now() + 3600_000).toISOString(), ends_at: new Date(Date.now() + 10_800_000).toISOString(), timezone: 'Pacific/Guam' }
  const payload = { schema_version: 1, event, version: 1, generated_at: new Date(Date.now() - 1000).toISOString(), expires_at: new Date(Date.now() + 86_400_000).toISOString(), tickets }
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  const publicDer = publicKey.export({ type: 'spki', format: 'der' })
  const digest = crypto.createHash('sha256').update(canonicalJson(payload)).digest('hex')
  const signature = crypto.sign('sha256', digest, {
    key: privateKey,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: 32,
  }).toString('base64url')
  return {
    payload,
    digest,
    signature,
    algorithm: 'PS256',
    key_id: crypto.createHash('sha256').update(publicDer).digest('hex'),
    public_key_spki: publicDer.toString('base64'),
  }
}


function build(revision, marker, legacy = false) {
  execFileSync(process.execPath, ['node_modules/vite/bin/vite.js', 'build', '--config', 'e2e-pwa/vite.config.js', '--outDir', 'tmp/pwa-deploy'], {
    env: { ...process.env, COMMIT_REF: revision, PWA_TEST_MARKER: marker, PWA_TEST_LEGACY_SW: legacy ? '1' : '', SENTRY_AUTH_TOKEN: '',
      VITE_CLERK_PUBLISHABLE_KEY: '', VITE_PUBLIC_WEB_URL: '', VITE_API_URL: `${origin}/api/v1` },
    stdio: 'pipe', timeout: 90_000,
  })
}
async function serve(worker) {
  const server = spawn(process.execPath, ['e2e-pwa/server.js'], { stdio: ['pipe', 'pipe', 'pipe', 'ipc'] })
  if (process.env.DEV_LIFECYCLE_SESSION) execFileSync('dev-lifecycle', ['claim', '--session', process.env.DEV_LIFECYCLE_SESSION, 'process', String(server.pid), '--reason', 'PWA deploy fixture server'])
  server.requests = []
  server.on('message', message => { if (message.type === 'api-request') server.requests.push(message) })
  let output = ''
  server.stderr.on('data', data => { output += data })
  try {
    await configure(server, { worker, api: apiFixtures })
    await expect.poll(async () => {
      if (server.exitCode !== null || server.signalCode !== null) throw Error(output)
      try { return (await fetch(origin)).ok } catch { return false }
    }).toBe(true)
  } catch (error) { await stop(server); throw error }
  return server
}
async function configure(server, message) {
  if (message.api) apiFixtures = { ...apiFixtures, ...message.api }
  await new Promise((resolve, reject) => {
    const finish = error => {
      clearTimeout(timer)
      server.off('message', onMessage)
      server.off('exit', onExit)
      if (error) reject(error)
      else resolve()
    }
    const onMessage = value => { if (value === 'configured') finish() }
    const onExit = () => finish(new Error('Fixture exited before configuration'))
    const timer = setTimeout(() => finish(new Error('Fixture configuration timed out')), 5000)
    server.on('message', onMessage)
    server.once('exit', onExit)
    server.send(message, error => { if (error) finish(error) })
  })
}
async function stop(server) {
  if (!server || server.exitCode !== null || server.signalCode !== null) return
  const exited = once(server, 'exit')
  server.kill('SIGTERM')
  await exited
}
async function installed(page) {
  await page.waitForFunction(() => Boolean(navigator.serviceWorker.controller), null, { timeout: 15_000 })
}
async function prepare(server) {
  const event = { id: 42, slug: 'deploy-test', title: 'Synthetic deploy event', status: 'published', starts_at: '2099-10-11T08:00:00Z', timezone: 'Pacific/Guam', purchasable: true, fee_policy: 'organizer_absorbs', buyer_fee_percent: 0,
    ticket_types: [{ id: 1, name: 'General', price_cents: 1000, current_price_cents: 1000, quantity_remaining: 10, on_sale: true }] }
  // Serve API fixtures over HTTP so service-worker-owned fetches exercise the
  // same transport in Chromium and WebKit.
  await configure(server, { api: {
    '/api/v1/health': { status: 'ok' },
    '/api/v1/config': { payment_mode: 'simulate', buyer_terms_version: 'qa-v1', service_fee_percent: 0, service_fee_flat_cents: 0 },
    '/api/v1/me': { id: 7, role: 'organizer' },
    '/api/v1/events': { events: [] },
    '/api/v1/events/deploy-test': event,
  } })
  return event
}

test('legacy A upgrades to B, B fetches C on first navigation, and protected/offline work survives', async ({ browser }, testInfo) => {
  let server
  const contexts = []
  try {
    apiFixtures = {}
    build(A, 'A', true)
    expect(readFileSync('tmp/pwa-deploy/sw.js', 'utf8')).toContain('createHandlerBoundToURL')
    server = await serve()
    const pages = []
    let event
    for (const width of [1280, 390, 1280, 390, 390]) {
      const context = await browser.newContext({ viewport: { width, height: 900 } })
      contexts.push(context)
      const page = await context.newPage()
      event = await prepare(server)
      pages.push(page)
    }
    const [home, checkout, scanner, selection, ticket] = pages
    await scanner.addInitScript(() => localStorage.setItem('hafapass_scanner_user_id', 'synthetic-operator'))
    await home.goto(origin)
    await installed(home)
    await expect(home.locator('#deploy-marker')).toHaveText('Build A')
    await checkout.goto(`${origin}/events/deploy-test`)
    await installed(checkout)
    await checkout.getByRole('button', { name: 'Increase quantity for General', exact: true }).click()
    await checkout.getByRole('button', { name: /Buy Tickets/ }).click()
    await checkout.getByLabel('Full Name').fill('Unsaved buyer')
    await checkout.evaluate(() => { window.originalCheckoutDocument = true })

    await selection.goto(`${origin}/events/deploy-test`)
    await installed(selection)
    await selection.getByRole('button', { name: 'Increase quantity for General', exact: true }).click()
    await selection.evaluate(() => { window.originalSelectionDocument = true })

    const syntheticTicket = {
      id: 1, code: 'HP-DEPLOY-TICKET', status: 'issued', admission_allowed: true, scan_credential: 'synthetic-entry-code', event, attendee_name: 'Synthetic Guest',
      ticket_type: { name: 'General' },
    }
    await configure(server, { api: { '/api/v1/tickets/synthetic-ticket': syntheticTicket } })
    await ticket.goto(`${origin}/tickets/synthetic-ticket`)
    await installed(ticket)
    await expect(ticket.getByRole('heading', { name: 'Synthetic deploy event', exact: true })).toBeVisible()
    await ticket.evaluate(() => { window.originalTicketDocument = true })

    const credential = 'synthetic-deploy-offline-ticket'
    const manifest = signedManifest([{ ticket_id: 1, code: 'HP-DEPLOY', credential_hash: crypto.createHash('sha256').update(credential).digest('hex'), attendee_name: 'Synthetic Guest', ticket_type: 'General', state: 'valid' }])
    const device = { id: 8, identifier: 'deploy-test', effective: true, status: 'active', authorization_expires_at: new Date(Date.now() + 86_400_000).toISOString(), last_sequence: 0 }
    await configure(server, { api: {
      '/api/v1/organizer/events': { events: [{ id: 42, title: 'Guam Night Market', status: 'published' }] },
      '/api/v1/organizer/events/42/scanner_devices': device,
      '/api/v1/organizer/events/42/scanner_devices/8/manifest': manifest,
      '/api/v1/organizer/events/42/admissions': { counts: {}, devices: [device], recent_actions: [] },
    } })
    await scanner.goto(`${origin}/dashboard/scanner?event=42`)
    await installed(scanner)
    await scanner.getByText('Device details', { exact: true }).click()
    await expect(scanner.getByText('Saved ticket list · version 1 · 1 tickets')).toBeVisible()
    await scanner.evaluate(() => { window.originalScannerDocument = true })

    await stop(server)
    build(B, 'B')
    const workerB = readFileSync('tmp/pwa-deploy/sw.js', 'utf8')
    for (const route of ['ScannerPage', 'BoxOfficePage', 'purchaseFlow']) expect(workerB).toContain(`assets/${route}-`)
    expect(workerB).not.toMatch(/assets\/(?:Admin|MarketplaceAdminPage|ProviderReadinessPage|(?:ja|ko|tl|zh|zh-Hant)-)/)
    server = await serve()
    // The one revisit starts with A's precached shell, then picks up B itself.
    await home.goto(origin)
    await expect(home.locator('#deploy-marker')).toHaveText('Build B', { timeout: 20_000 })
    expect(await home.evaluate(revision => sessionStorage.getItem('hafapass_release_reload:' + revision), B)).toBe('1')
    await home.screenshot({ path: testInfo.outputPath('home-build-b.png'), fullPage: true })
    for (const page of [checkout, scanner, selection, ticket]) {
      await page.evaluate(async () => {
        const registration = await navigator.serviceWorker.getRegistration()
        const controlled = new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }))
        await registration.update()
        await controlled
      })
      // Verify B is controlling; allow update callbacks to settle before deferral assertions.
      await expect.poll(() => page.evaluate(async () => (await (await fetch('/index.html')).text()).includes('Build B'))).toBe(true)
    }
    await checkout.waitForTimeout(2_000)
    await expect(checkout.locator('#deploy-marker')).toHaveText('Build A')
    await expect(checkout.getByLabel('Full Name')).toHaveValue('Unsaved buyer')
    expect(await checkout.evaluate(() => window.originalCheckoutDocument)).toBe(true)
    await checkout.screenshot({ path: testInfo.outputPath('checkout-preserved.png'), fullPage: true })
    // A hidden transaction must remain protected as well.
    for (const page of [checkout, selection]) {
      await page.evaluate(() => {
        Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' })
        document.dispatchEvent(new Event('visibilitychange'))
      })
    }
    // A forbidden reload is observable as Build B or a lost document/selection.
    await selection.waitForTimeout(2_000)
    await expect(selection.locator('#deploy-marker')).toHaveText('Build A')
    expect(await selection.evaluate(() => window.originalSelectionDocument)).toBe(true)
    await selection.screenshot({ path: testInfo.outputPath('selection-preserved.png'), fullPage: true })
    await selection.getByRole('button', { name: /Buy Tickets/ }).click()
    await expect(selection.getByLabel('Full Name')).toBeVisible()
    await expect(selection.locator('#deploy-marker')).toHaveText('Build A')
    // The same A document must also complete the task after B removed A assets.
    const order = { id: 99, reference: 'HP-DEPLOY', status: 'completed', buyer_name: 'Synthetic Buyer', buyer_email: 'buyer@example.invalid', guest_access_token: 'synthetic-order-access',
      subtotal_cents: 1000, service_fee_cents: 0, discount_cents: 0, total_cents: 1000, refunded_cents: 0, event,
      order_items: [{ id: 1, name: 'General', quantity: 1, subtotal_cents: 1000 }], tickets: [] }
    await configure(server, { api: { '/api/v1/orders': order, '/api/v1/orders/99': order } })
    await selection.getByLabel('Full Name').fill('Synthetic Buyer')
    await selection.getByLabel('Email Address').fill('buyer@example.invalid')
    await selection.locator('input#termsAccepted:visible').check()
    await selection.getByRole('button', { name: /Place Order/ }).click()
    await expect(selection.getByRole('heading', { name: 'Your order is confirmed' })).toBeVisible()
    expect(server.requests.find(request => request.path === '/api/v1/orders' && request.method === 'POST')?.body.line_items).toEqual([{ ticket_type_id: 1, quantity: 1 }])
    await expect(selection.locator('#deploy-marker')).toHaveText('Build A')
    await expect(checkout.getByLabel('Full Name')).toHaveValue('Unsaved buyer')
    // Use the application's navigation, which discards the departed form.
    await checkout.getByRole('link', { name: /HåfaPass/ }).first().click()
    await expect(checkout.locator('#deploy-marker')).toHaveText('Build B', { timeout: 15_000 })

    await expect(ticket.locator('#deploy-marker')).toHaveText('Build A')
    expect(await ticket.evaluate(() => window.originalTicketDocument)).toBe(true)
    await stop(server)
    await contexts[4].setOffline(true)
    // Already-rendered ticket stays available. As before, ticket JSON is not
    // cached: reloading offline offers recovery rather than inventing access.
    await expect(ticket.getByRole('heading', { name: 'Synthetic deploy event', exact: true })).toBeVisible()
    await ticket.reload()
    await expect(ticket.locator('#deploy-marker')).toHaveText('Build B')
    await expect(ticket.getByText("We couldn't load this ticket.", { exact: true })).toBeVisible()
    server = await serve()

    // A never-visited navigation must time out to the precached shell even
    // though NetworkFirst has no runtime response cached at this URL.
    const started = Date.now()
    const timeoutResponse = await home.goto(`${origin}/timeout-never-visited`)
    expect(await timeoutResponse.text()).toContain('Build B')
    expect(Date.now() - started).toBeGreaterThanOrEqual(2500)
    expect(Date.now() - started).toBeLessThan(9000)
    for (const path of ['/network-error', '/server-error']) {
      const response = await home.goto(`${origin}${path}`)
      expect(await response.text()).toContain('Build B')
    }
    for (const path of ['/api/test', '/robots.txt', '/sitemap.xml', '/assets/missing-hash.js']) {
      const response = await home.goto(`${origin}${path}`)
      expect(await response.text()).not.toContain('deploy-marker')
      if (path.startsWith('/assets/')) expect(response.status()).toBe(404)
    }

    // Hold B's worker at the server while deploying C. Neither a worker
    // replacement nor the coordinator can disguise a stale first response.
    const bWorker = readFileSync('tmp/pwa-deploy/sw.js', 'utf8')
    await stop(server)
    build(C, 'C')
    server = await serve(bWorker)
    for (const path of ['/', '/index.html', '/events?first-navigation=C']) {
      const response = await home.goto(`${origin}${path}`)
      expect(await response.text()).toContain('Build C')
      await expect(home.locator('#deploy-marker')).toHaveText('Build C')
      expect(await home.evaluate(async () => (await (await fetch('/index.html')).text()).includes('Build B'))).toBe(true)
    }

    expect(await scanner.evaluate(() => window.originalScannerDocument)).toBe(true)
    // Stop the origin as well as disconnecting the context: worker-owned
    // requests must experience real transport failure on both engines.
    await stop(server)
    await contexts[2].setOffline(true)
    await scanner.reload()
    await expect(scanner.locator('#deploy-marker')).toHaveText('Build B')
    await expect(scanner.getByText('Using this device’s saved event access.', { exact: false })).toBeVisible()
    await scanner.getByLabel('Ticket QR code').fill(credential)
    await scanner.getByRole('button', { name: 'Check in ticket' }).click()
    await expect(scanner.getByText('Admitted offline', { exact: true })).toBeVisible()
    await expect(scanner.getByTestId('scanner-pending-count')).toHaveText('1')
    await scanner.reload()
    await expect(scanner.getByTestId('scanner-pending-count')).toHaveText('1')
    await scanner.screenshot({ path: testInfo.outputPath('offline-scanner.png'), fullPage: true })
    await scanner.goto(`${origin}/offline.html`)
    await expect(scanner.getByRole('heading')).toContainText(/offline/i)
    await scanner.screenshot({ path: testInfo.outputPath('offline-html.png'), fullPage: true })
    await testInfo.attach('deploy-evidence', { body: JSON.stringify({ buildA: A, buildB: B, buildC: C, home: 'B after one legacy revisit; C on first network response at /, /index.html and a deep link with B worker frozen', timeout: 'never-visited URL fell back in 3 seconds; network error and 503 fell back', denylist: 'API, robots, sitemap and missing assets never receive shell fallback', selection: 'A quantity retained while hidden through B activation; checkout and simulated order confirmation complete with the retained quantity', checkout: 'A draft retained until app navigation; B at destination', ticket: 'A document retained through B activation and disconnect; offline reload preserves existing uncached-JSON recovery', scanner: 'prepared on A, offline reload on B after C deployed, admitted and persisted one pending scan', offlineHtml: 'served offline' }, null, 2), contentType: 'application/json' })
  } finally {
    try { await Promise.all(contexts.map(context => context.close())) }
    finally {
      await stop(server)
      rmSync('tmp/pwa-deploy', { recursive: true, force: true })
    }
  }
})


test('an unknown-revision production build still installs the offline shell', async ({ browser }) => {
  let server
  const context = await browser.newContext()
  try {
    apiFixtures = {}
    // An invalid authoritative revision yields the same null metadata as a source
    // archive without Git; it also overrides this test checkout's Git revision.
    build('unknown', 'unknown')
    server = await serve()
    const page = await context.newPage()
    await prepare(server)
    await page.goto(origin)
    await expect(page.locator('meta[name="hafapass-revision"]')).toHaveAttribute('content', '')
    expect(await page.evaluate(async () => (await (await fetch('/release.json')).json()).revision)).toBeNull()
    await installed(page)
    await context.setOffline(true)
    await page.goto(`${origin}/offline.html`)
    await expect(page.getByRole('heading')).toContainText(/offline/i)
    expect(await page.evaluate(() => Object.keys(sessionStorage).filter(key => key.startsWith('hafapass_release_reload:')))).toEqual([])
  } finally {
    try { await context.close() }
    finally {
      await stop(server)
      rmSync('tmp/pwa-deploy', { recursive: true, force: true })
    }
  }
})
