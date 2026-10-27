import crypto from 'node:crypto'
import process from 'node:process'
import { execFileSync, spawn } from 'node:child_process'
import { once } from 'node:events'
import { rmSync } from 'node:fs'
import { expect, test } from '@playwright/test'

const A = 'a'.repeat(40)
const B = 'b'.repeat(40)
const origin = 'http://127.0.0.1:5234'
const json = (route, body) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) })
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


function build(revision, marker) {
  execFileSync(process.execPath, ['node_modules/vite/bin/vite.js', 'build', '--config', 'e2e-pwa/vite.config.js', '--outDir', 'tmp/pwa-deploy'], {
    env: { ...process.env, COMMIT_REF: revision, PWA_TEST_MARKER: marker, SENTRY_AUTH_TOKEN: '',
      VITE_CLERK_PUBLISHABLE_KEY: '', VITE_PUBLIC_WEB_URL: '', VITE_API_URL: '' },
    stdio: 'pipe', timeout: 90_000,
  })
}
async function serve() {
  const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', '5234', '--strictPort', '--outDir', 'tmp/pwa-deploy'], { stdio: 'pipe' })
  if (process.env.DEV_LIFECYCLE_SESSION) execFileSync('dev-lifecycle', ['claim', '--session', process.env.DEV_LIFECYCLE_SESSION, 'process', String(server.pid), '--reason', 'Two-build preview server'])
  let output = ''
  server.stderr.on('data', data => { output += data })
  try {
    await expect.poll(async () => {
      if (server.exitCode !== null || server.signalCode !== null) throw Error(output)
      try { return (await fetch(origin)).ok } catch { return false }
    }).toBe(true)
  } catch (error) { await stop(server); throw error }
  return server
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
async function prepare(page) {
  await page.context().route('**/api/v1/**', route => json(route, {}))
  await page.context().route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.context().route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', buyer_terms_version: 'qa-v1', service_fee_percent: 0, service_fee_flat_cents: 0 }))
  await page.context().route('**/api/v1/me', route => json(route, { id: 7, role: 'organizer' }))
  await page.context().route(/\/api\/v1\/events(?:\?.*)?$/, route => json(route, { events: [] }))
  const event = { id: 42, slug: 'deploy-test', title: 'Synthetic deploy event', status: 'published', starts_at: '2099-10-11T08:00:00Z', timezone: 'Pacific/Guam', purchasable: true, fee_policy: 'organizer_absorbs', buyer_fee_percent: 0,
    ticket_types: [{ id: 1, name: 'General', price_cents: 1000, current_price_cents: 1000, quantity_remaining: 10, on_sale: true }] }
  await page.context().route('**/api/v1/events/deploy-test', route => json(route, event))
  return event
}

test('two deploys refresh Home once, preserve selection and checkout, and keep scanner offline', async ({ browser }, testInfo) => {
  let server
  const contexts = []
  try {
    build(A, 'A')
    server = await serve()
    const pages = []
    let event
    for (const width of [1280, 390, 1280, 390]) {
      const context = await browser.newContext({ viewport: { width, height: 900 } })
      contexts.push(context)
      const page = await context.newPage()
      event = await prepare(page)
      pages.push(page)
    }
    const [home, checkout, scanner, selection] = pages
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

    const credential = 'synthetic-deploy-offline-ticket'
    const manifest = signedManifest([{ ticket_id: 1, code: 'HP-DEPLOY', credential_hash: crypto.createHash('sha256').update(credential).digest('hex'), attendee_name: 'Synthetic Guest', ticket_type: 'General', state: 'valid' }])
    const device = { id: 8, identifier: 'deploy-test', effective: true, status: 'active', authorization_expires_at: new Date(Date.now() + 86_400_000).toISOString(), last_sequence: 0 }
    await scanner.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route, { events: [{ id: 42, title: 'Guam Night Market', status: 'published' }] }))
    await scanner.route('**/api/v1/organizer/events/42/scanner_devices', route => json(route, device))
    await scanner.route('**/api/v1/organizer/events/42/scanner_devices/8/manifest', route => json(route, manifest))
    await scanner.route('**/api/v1/organizer/events/42/admissions', route => json(route, { counts: {}, devices: [device], recent_actions: [] }))
    await scanner.goto(`${origin}/dashboard/scanner?event=42`)
    await installed(scanner)
    await scanner.getByText('Device details', { exact: true }).click()
    await expect(scanner.getByText('Saved ticket list · version 1 · 1 tickets')).toBeVisible()
    await scanner.evaluate(() => { window.originalScannerDocument = true })

    await stop(server)
    build(B, 'B')
    server = await serve()
    // The one revisit starts with A's precached shell, then picks up B itself.
    await home.goto(origin)
    await expect(home.locator('#deploy-marker')).toHaveText('Build B', { timeout: 20_000 })
    expect(await home.evaluate(revision => sessionStorage.getItem('hafapass_release_reload:' + revision), B)).toBe('1')
    await home.screenshot({ path: testInfo.outputPath('home-build-b.png'), fullPage: true })
    for (const page of [checkout, scanner, selection]) {
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
    let submitted
    const order = { id: 99, reference: 'HP-DEPLOY', status: 'completed', buyer_name: 'Synthetic Buyer', buyer_email: 'buyer@example.invalid', guest_access_token: 'synthetic-order-access',
      subtotal_cents: 1000, service_fee_cents: 0, discount_cents: 0, total_cents: 1000, refunded_cents: 0, event,
      order_items: [{ id: 1, name: 'General', quantity: 1, subtotal_cents: 1000 }], tickets: [] }
    await selection.route('**/api/v1/orders', route => { submitted = route.request().postDataJSON(); return json(route, order) })
    await selection.route('**/api/v1/orders/99', route => json(route, order))
    await selection.getByLabel('Full Name').fill('Synthetic Buyer')
    await selection.getByLabel('Email Address').fill('buyer@example.invalid')
    await selection.locator('input#termsAccepted:visible').check()
    await selection.getByRole('button', { name: /Place Order/ }).click()
    await expect(selection.getByRole('heading', { name: 'Your order is confirmed' })).toBeVisible()
    expect(submitted.line_items).toEqual([{ ticket_type_id: 1, quantity: 1 }])
    await expect(selection.locator('#deploy-marker')).toHaveText('Build A')
    await expect(checkout.getByLabel('Full Name')).toHaveValue('Unsaved buyer')
    // Use the application's navigation, which discards the departed form.
    await checkout.getByRole('link', { name: /HåfaPass/ }).first().click()
    await expect(checkout.locator('#deploy-marker')).toHaveText('Build B', { timeout: 15_000 })

    expect(await scanner.evaluate(() => window.originalScannerDocument)).toBe(true)
    // Route.fulfill mocks can answer even in an offline browser context. Remove
    // them so this phase exercises real transport failure and the saved shell.
    await scanner.unrouteAll({ behavior: 'wait' })
    await contexts[2].unrouteAll({ behavior: 'wait' })
    await contexts[2].setOffline(true)
    await scanner.reload()
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
    await testInfo.attach('deploy-evidence', { body: JSON.stringify({ buildA: A, buildB: B, home: 'B after one revisit', selection: 'A quantity retained while hidden through B activation; checkout and simulated order confirmation complete with the retained quantity', checkout: 'A draft retained until app navigation; B at destination', scanner: 'prepared on A, offline reload on B, admitted and persisted one pending scan', offlineHtml: 'served offline' }, null, 2), contentType: 'application/json' })
  } finally {
    await Promise.all(contexts.map(context => context.close()))
    await stop(server)
    rmSync('tmp/pwa-deploy', { recursive: true, force: true })
  }
})


test('an unknown-revision production build still installs the offline shell', async ({ browser }) => {
  let server
  const context = await browser.newContext()
  try {
    // An invalid authoritative revision yields the same null metadata as a source
    // archive without Git; it also overrides this test checkout's Git revision.
    build('unknown', 'unknown')
    server = await serve()
    const page = await context.newPage()
    await prepare(page)
    await page.goto(origin)
    await expect(page.locator('meta[name="hafapass-revision"]')).toHaveAttribute('content', '')
    expect(await page.evaluate(async () => (await (await fetch('/release.json')).json()).revision)).toBeNull()
    await installed(page)
    await context.unrouteAll({ behavior: 'wait' })
    await context.setOffline(true)
    await page.goto(`${origin}/offline.html`)
    await expect(page.getByRole('heading')).toContainText(/offline/i)
    expect(await page.evaluate(() => Object.keys(sessionStorage).filter(key => key.startsWith('hafapass_release_reload:')))).toEqual([])
  } finally {
    await context.close()
    await stop(server)
    rmSync('tmp/pwa-deploy', { recursive: true, force: true })
  }
})
