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
  const device = { id: 8, identifier: 'browser-test', name: 'North door', effective: true, status: 'active', authorization_expires_at: new Date(Date.now() + 86_400_000).toISOString(), last_sequence: 0 }
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
})

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
