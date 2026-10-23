import crypto from 'node:crypto'
import { expect, test } from '@playwright/test'

const json = (route, data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(data) })
const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]`
  : value && typeof value === 'object' ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`
    : JSON.stringify(value)
const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
function manifest(id, credential) {
  const payload = { schema_version: 1, event: { id, title: `Context event ${id}` }, version: 2,
    expires_at: new Date(Date.now() + 600_000).toISOString(), tickets: [{ ticket_id: 501, code: 'HP-T501',
      attendee_name: 'José & Ana', ticket_type: 'Admission', state: 'valid',
      credential_hash: crypto.createHash('sha256').update(credential).digest('hex') }] }
  const digest = crypto.createHash('sha256').update(canonical(payload)).digest('hex')
  const spki = keys.publicKey.export({ type: 'spki', format: 'der' })
  return { payload, digest, algorithm: 'PS256', key_id: crypto.createHash('sha256').update(spki).digest('hex'),
    public_key_spki: spki.toString('base64'), signature: crypto.sign('sha256', digest,
      { key: keys.privateKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64url') }
}

test('an earlier setup refusal cannot erase the current scanner or its accepted receipt', async ({ page }) => {
  const credential = 'synthetic-context-credential'
  const manifests = new Map([42, 43].map(id => [id, manifest(id, credential)]))
  const device = id => ({ id, identifier: `context-${id}`, effective: true, status: 'active', last_sequence: 0,
    authorization_expires_at: new Date(Date.now() + 600_000).toISOString() })
  let oldRegistration
  let registrations = 0
  const sent = []
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { environment: 'test', launch_capabilities: {} }))
  await page.route('**/api/v1/me', route => json(route, { id: 7, role: 'organizer' }))
  await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route,
    { events: [42, 43].map(id => ({ id, title: `Context event ${id}` })) }))
  await page.route('**/api/v1/organizer/events/*/scanner_devices', route => {
    if (++registrations === 1) { oldRegistration = route; return }
    return json(route, device(route.request().url().includes('/43/') ? 9 : 8), 201)
  })
  await page.route('**/api/v1/organizer/events/*/scanner_devices/*/manifest', route =>
    json(route, manifests.get(route.request().url().includes('/43/') ? 43 : 42)))
  await page.route('**/api/v1/organizer/events/*/admissions', route => json(route, { counts: {}, permissions: {}, recent_actions: [] }))
  await page.route('**/api/v1/organizer/events/42/scanner_devices/8/sync', route => {
    const actions = route.request().postDataJSON().actions
    sent.push(...actions)
    return json(route, { device: { ...device(8), last_sequence: actions.at(-1).sequence }, summary: {},
      results: actions.map(action => ({ ...action, result: 'accepted', reason_code: 'admitted' })) })
  })
  await page.goto('/dashboard/scanner?event=42')
  await expect.poll(() => Boolean(oldRegistration)).toBe(true)
  await page.getByLabel('Event to scan').selectOption('43')
  await expectManifest(page, 'Saved ticket list · version 2 · 1 ticket')
  await page.getByLabel('Event to scan').selectOption('42')
  await expect(page.getByRole('button', { name: 'Sync now' })).toBeEnabled()
  await page.getByLabel('Ticket QR code').fill(credential)
  await page.getByRole('button', { name: 'Check in ticket', exact: true }).click()
  await expect(page.getByText('Admission confirmed', { exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Sync now' })).toBeEnabled()
  await json(oldRegistration, { error: 'Earlier setup refused' }, 403)
  // Observe the completed network callback and a browser turn before checking
  // its storage outcome through a fresh UI operation.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await page.getByLabel('Ticket QR code').fill(credential)
  await page.getByRole('button', { name: 'Check in ticket', exact: true }).click()
  await expect(page.getByText('Already scanned on this device', { exact: true })).toBeVisible()
  await expect(page.getByText('Earlier setup refused', { exact: true })).toHaveCount(0)
  await expectManifest(page, 'Saved ticket list · version 2 · 1 ticket')
  expect(sent).toHaveLength(1)
})

async function expectManifest(page, text) {
  const summary = page.getByText('Device details', { exact: true })
  if (await summary.locator('..').getAttribute('open') === null) await summary.click()
  await expect(page.getByText(text)).toBeVisible()
}
