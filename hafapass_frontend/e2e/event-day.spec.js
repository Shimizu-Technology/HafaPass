import crypto from 'node:crypto'
import { expect, test } from '@playwright/test'

function json(route, body, status = 200) {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
}

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

test.beforeEach(async ({ page }) => {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: { door_card: true } }))
  await page.route('**/api/v1/me', route => json(route, { id: 7, role: 'organizer' }))
})

test('scanner validates locally, records an offline scan, and reconciles it after reconnecting', async ({ page, context }) => {
  const credentials = ['ticket-one-secret', 'ticket-two-secret']
  const manifest = signedManifest(credentials.map((credential, index) => ({
    ticket_id: index + 1,
    code: `HP-T${index + 1}`,
    credential_hash: crypto.createHash('sha256').update(credential).digest('hex'),
    attendee_name: index ? 'Jose Cruz' : 'Mina Cruz',
    ticket_type: 'General Admission',
    state: 'valid',
  })))
  const device = { id: 8, identifier: 'browser-test', name: 'North door', effective: true, status: 'active', authorization_expires_at: new Date(Date.now() + 86_400_000).toISOString(), last_sequence: 0, user: { id: 7, name: 'Door Staff' } }
  const syncedActions = []

  await page.route('**/api/v1/organizer/events', route => json(route, { events: [{ id: 42, title: 'Guam Night Market', status: 'published' }], meta: {} }))
  await page.route('**/api/v1/organizer/events/42/scanner_devices', route => json(route, device, 201))
  await page.route('**/api/v1/organizer/events/42/scanner_devices/8/manifest', route => json(route, manifest))
  await page.route('**/api/v1/organizer/events/42/admissions', route => json(route, {
    counts: { admitted: syncedActions.length, remaining: 2 - syncedActions.length, conflicts: 0, rejected: 0 },
    devices: [device], recent_actions: [], permissions: { can_reverse: true },
  }))
  await page.route('**/api/v1/organizer/events/42/scanner_devices/8/sync', async route => {
    const actions = route.request().postDataJSON().actions
    syncedActions.push(...actions)
    return json(route, {
      results: actions.map(action => ({ ...action, result: 'accepted', reason_code: 'admitted', attendee: {} })),
      device: { ...device, last_sequence: actions.at(-1).sequence },
      summary: { admitted: syncedActions.length, remaining: 2 - syncedActions.length, conflicts: 0, rejected: 0 },
    })
  })

  await page.goto('/dashboard/scanner')
  await expect(page.getByText('Manifest v1 · 2 tickets')).toBeVisible()
  await context.setOffline(true)
  await page.getByPlaceholder('Ticket QR credential').fill(credentials[1])
  await page.getByRole('button', { name: 'Validate' }).click()
  await expect(page.getByText('Admitted offline')).toBeVisible()
  await expect(page.getByTestId('scanner-pending-count')).toHaveText('1')

  await page.getByPlaceholder('Ticket QR credential').fill(credentials[1])
  await page.getByRole('button', { name: 'Validate' }).click()
  await expect(page.getByText('Already scanned on this device')).toBeVisible()

  await context.setOffline(false)
  await expect.poll(() => syncedActions.length).toBe(1)
  await expect(page.getByTestId('scanner-pending-count')).toHaveText('0')

  // The app shell can reload while its API is unavailable; verified IndexedDB access remains usable.
  await page.route('**/api/v1/health', route => json(route, { status: 'unavailable' }, 503))
  await page.reload()
  await expect(page.getByText('Using this device’s saved event access.', { exact: false })).toBeVisible()
  await expect(page.getByText('Manifest v1 · 2 tickets')).toBeVisible()
  await page.getByLabel('Ticket QR credential').fill(credentials[0])
  await page.getByRole('button', { name: 'Validate' }).click()
  await expect(page.getByText('Admitted offline')).toBeVisible()
  await expect(page.getByTestId('scanner-pending-count')).toHaveText('1')

  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.getByRole('button', { name: 'Check connection', exact: true }).click()
  await expect.poll(() => syncedActions.length).toBe(2)
  await expect(page.getByTestId('scanner-pending-count')).toHaveText('0')
})

for (const viewport of [{ width: 390, height: 844 }, { width: 1440, height: 900 }]) {
  test(`manager identifies same-name tickets and selects the correct Undo at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport)
    const tickets = [1, 2].map(ticket_id => ({ ticket_id, code: `HP-T${ticket_id}`, attendee_name: 'José & Ana',
      ticket_type: 'General Admission', state: 'admitted', credential_hash: 'c'.repeat(64) }))
    const manifest = signedManifest(tickets)
    const device = { id: 8, identifier: 'history-browser', effective: true, status: 'active', last_sequence: 0,
      authorization_expires_at: new Date(Date.now() + 600_000).toISOString() }
    const synced = []
    await page.route('**/api/v1/organizer/events', route => json(route, { events: [{ id: 42, title: 'Guam Night Market' }] }))
    await page.route('**/api/v1/organizer/events/42/scanner_devices', route => json(route, device, 201))
    await page.route('**/api/v1/organizer/events/42/scanner_devices/8/manifest', route => json(route, manifest))
    await page.route('**/api/v1/organizer/events/42/admissions', route => json(route, {
      counts: { admitted: 1, remaining: 1, conflicts: 0, rejected: 0 }, permissions: { can_reverse: true },
      recent_actions: tickets.map(ticket => ({ action_uuid: `original-${ticket.ticket_id}`, ticket_id: ticket.ticket_id,
        kind: 'admit', result: 'accepted', reversed: ticket.ticket_id === 1, attendee: { code: ticket.code, attendee_name: ticket.attendee_name } })),
    }))
    await page.route('**/api/v1/organizer/events/42/scanner_devices/8/sync', route => {
      const actions = route.request().postDataJSON().actions
      synced.push(...actions)
      return json(route, { device: { ...device, last_sequence: actions.at(-1).sequence },
        results: actions.map(action => ({ ...action, result: 'accepted', reason_code: 'reversed' })), summary: {} })
    })
    await page.goto('/dashboard/scanner?event=42')
    await expect(page.getByText('Manifest v1 · 2 tickets')).toBeVisible()
    await expect(page.getByText('José & Ana', { exact: true })).toHaveCount(2)
    for (const code of ['HP-T1', 'HP-T2']) await expect(page.getByText(code, { exact: true })).toBeVisible()
    const reversed = page.getByRole('button', { name: 'Reversed admission for HP-T1' })
    const undo = page.getByRole('button', { name: 'Undo admission for HP-T2' })
    await expect(reversed).toBeDisabled()
    await expect(undo).toBeEnabled()
    for (const control of [reversed, undo]) {
      const bounds = await control.boundingBox()
      expect(bounds.width).toBeGreaterThanOrEqual(44)
      expect(bounds.height).toBeGreaterThanOrEqual(44)
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
    await undo.click()
    await expect(page.getByText('Admission reversal confirmed', { exact: true })).toBeVisible()
    expect(synced).toHaveLength(1)
    expect(synced[0]).toMatchObject({ kind: 'reverse', reverses_action_uuid: 'original-2', ticket_id: 2 })
  })
}

test('box office exposes card sales only for a verified terminal and sends an idempotency key', async ({ page }) => {
  let receivedIdempotencyKey
  const event = {
    id: 42,
    title: 'Guam Night Market',
    ticket_types: [{ id: 2, name: 'General Admission', price_cents: 2500, quantity_available: 100, quantity_sold: 5, door_allocation: 20, door_sold_quantity: 2, door_available_quantity: 18 }],
  }
  await page.route('**/api/v1/organizer/events/42', route => json(route, event))
  await page.route('**/api/v1/organizer/card_present_account', route => json(route, { provider: 'boh_clover', status: 'verified', payment_ready: true }))
  await page.route('**/api/v1/organizer/events/42/box_office/summary', route => json(route, { total_orders: 0, total_tickets: 0, total_revenue_cents: 0, by_payment_method: {} }))
  await page.route('**/api/v1/organizer/events/42/box_office', async route => {
    receivedIdempotencyKey = route.request().headers()['idempotency-key']
    return json(route, {
      id: 99, status: 'completed', buyer_name: 'Walk-in', buyer_email: 'walkin@example.com', total_cents: 2500,
      source: 'box_office', payment_method: 'door_card', card_present_payment: { status: 'succeeded', provider: 'boh_clover' },
      tickets: [{ id: 77, scan_credential: 'issued-secret', ticket_type: { name: 'General Admission' } }],
    }, 201)
  })

  await page.goto('/dashboard/events/42/box-office')
  await page.getByRole('button', { name: 'Add General Admission' }).click()
  await page.getByRole('button', { name: 'Card at Door' }).click()
  await page.getByRole('button', { name: /Process Sale/ }).click()

  await expect(page.getByText('Sale Complete!')).toBeVisible()
  expect(receivedIdempotencyKey).toMatch(/^box-office-/)
})

for (const scenario of [
  { name: 'a restricted launch scope', doorCard: false, paymentReady: true },
  { name: 'an unverified terminal', doorCard: true, paymentReady: false },
]) {
  test(`box office keeps card sales disabled for ${scenario.name}`, async ({ page }) => {
    await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: { door_card: scenario.doorCard } }))
    await page.route('**/api/v1/organizer/events/42', route => json(route, { id: 42, title: 'Door Event', ticket_types: [{ id: 2, name: 'General Admission', price_cents: 2500, quantity_available: 10, quantity_sold: 0 }] }))
    await page.route('**/api/v1/organizer/card_present_account', route => json(route, { payment_ready: scenario.paymentReady, status: scenario.paymentReady ? 'verified' : 'pending' }))
    await page.route('**/api/v1/organizer/events/42/box_office/summary', route => json(route, { total_orders: 0, total_tickets: 0, total_revenue_cents: 0, by_payment_method: {} }))
    await page.goto('/dashboard/events/42/box-office')
    await page.getByRole('button', { name: 'Add General Admission' }).click()
    await expect(page.getByRole('button', { name: 'Card at Door' })).toBeDisabled()
    await expect(page.getByRole('button', { name: 'Cash', exact: true })).toBeEnabled()
  })
}
