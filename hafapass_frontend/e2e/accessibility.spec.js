import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import crypto from 'node:crypto'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const event = {
  id: 601, slug: 'accessible-night', title: 'Accessible Community Night', status: 'published',
  description: 'Music and dinner for the community.', starts_at: '2099-10-11T08:00:00Z',
  timezone: 'Pacific/Guam', venue_name: 'Community Venue', purchasable: true,
  fee_policy: 'organizer_absorbs', buyer_fee_percent: 0,
  ticket_types: [{ id: 10, name: 'Admission', price_cents: 2000, current_price_cents: 2000,
    service_fee_cents: 0, quantity_remaining: 20, on_sale: true }],
}
const organizerEvent = { ...event, organization_id: 1, organization_name: 'Island Events', status: 'draft',
  category: 'other', publish_checklist: [], permissions: { edit_event_content: true, manage_events: true,
    manage_inventory: true, manage_attendees: true, view_attendees: true, manage_marketing: true,
    view_finance: true, refund: true, scan: true, box_office: true } }

function scannerManifest() {
  const payload = { schema_version: 1, event: { id: 42, title: 'Accessible Community Night', status: 'published',
    venue_name: 'Community Venue', starts_at: new Date(Date.now() + 3_600_000).toISOString(),
    ends_at: new Date(Date.now() + 10_800_000).toISOString(), timezone: 'Pacific/Guam' }, version: 1,
  generated_at: new Date(Date.now() - 1000).toISOString(), expires_at: new Date(Date.now() + 86_400_000).toISOString(),
  tickets: [{ ticket_id: 7, code: 'HP-T7', credential_hash: crypto.createHash('sha256').update('scan-test-7').digest('hex'),
    attendee_name: 'Mina Cruz', ticket_type: 'Admission', state: 'valid' }] }
  const canonicalJson = value => Array.isArray(value) ? `[${value.map(canonicalJson).join(',')}]`
    : value !== null && typeof value === 'object' ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`
      : JSON.stringify(value)
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  const publicDer = publicKey.export({ type: 'spki', format: 'der' })
  const digest = crypto.createHash('sha256').update(canonicalJson(payload)).digest('hex')
  return { payload, digest, signature: crypto.sign('sha256', digest, { key: privateKey,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64url'),
  algorithm: 'PS256', key_id: crypto.createHash('sha256').update(publicDer).digest('hex'),
  public_key_spki: publicDer.toString('base64') }
}

async function prepare(page) {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, {
    payment_mode: 'simulate', buyer_terms_version: 'qa-v1', launch_capabilities: {},
    service_fee_percent: 0, service_fee_flat_cents: 0, processing_fee_bearer: 'platform',
    policies: { 'buyer-terms': { title: 'Buyer Terms', summary: 'Purchase terms.',
      sections: [{ heading: 'Your purchase', body: 'Keep your receipt.' }] } },
  }))
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [] }))
  await page.route('**/api/v1/events/accessible-night', route => json(route, event))
  await page.route('**/api/v1/events?**', route => json(route, { events: [event], meta: { current_page: 1, total_pages: 1, total_count: 1 } }))
  await page.route('**/api/v1/marketplace*', route => json(route, {}))
  await page.route('**/api/v1/organizer/organizations', route => json(route, [{ id: 1, name: 'Island Events' }]))
  await page.route('**/api/v1/organizer/events/601', route => json(route, organizerEvent))
}

async function scan(page, journey) {
  const results = await new AxeBuilder({ page }).analyze()
  const blocking = results.violations.filter(violation => ['serious', 'critical'].includes(violation.impact))
  expect(blocking, `${journey}: ${blocking.map(v => `${v.id}: ${v.nodes.map(n => n.target.join(' ')).join(', ')}`).join('; ')}`).toEqual([])
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual((await page.viewportSize()).width)
  expect(await page.getByRole('main').count(), `${journey}: one main landmark`).toBe(1)
}

async function tabTo(page, locator) {
  await expect(locator).toHaveCount(1)
  for (let index = 0; index < 100; index += 1) {
    if (await locator.evaluate(element => element === document.activeElement)) return
    await page.keyboard.press('Tab')
  }
  throw new Error('Keyboard focus did not reach the expected control')
}

for (const width of [375, 1440]) {
  test(`buyer browse, event, ticket choice, checkout and policy at ${width}px`, async ({ page }) => {
    test.setTimeout(60_000)
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.goto('/events')
    await expect(page.getByRole('link', { name: /Accessible Community Night/ }).first()).toBeVisible()
    await scan(page, 'browse events')
    const eventLink = page.getByRole('link', { name: /Accessible Community Night/ }).first()
    await tabTo(page, eventLink)
    await page.keyboard.press('Enter')
    await expect(page.getByRole('heading', { level: 1, name: event.title })).toBeVisible()
    await scan(page, 'event page')
    const addTicket = page.getByRole('button', { name: 'Increase quantity for Admission' })
    await tabTo(page, addTicket)
    await page.keyboard.press('Enter')
    await expect(page.getByRole('button', { name: /Buy Tickets/ })).toContainText('$20.00')
    await scan(page, 'choose tickets')
    const buy = page.getByRole('button', { name: /Buy Tickets/ })
    await tabTo(page, buy)
    await page.keyboard.press('Enter')
    await expect(page).toHaveURL(/\/checkout\/accessible-night$/)
    await expect(page.getByLabel('Full Name')).toBeVisible()
    await scan(page, 'checkout')
    await page.goto('/policies/buyer-terms')
    await expect(page.getByRole('heading', { level: 1, name: 'Buyer Terms' })).toBeVisible()
    await scan(page, 'policy')
    await tabTo(page, page.getByRole('link', { name: /skip/i }))
    await page.keyboard.press('Enter')
    await expect(page.locator('#main-content')).toBeFocused()
  })

  test(`organizer event editing and ticket types at ${width}px`, async ({ page }) => {
    test.setTimeout(60_000)
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.goto('/dashboard/events/601/edit')
    const title = page.getByLabel(/Event Title/)
    await expect(title).toHaveValue(event.title)
    await scan(page, 'organizer edit event')
    await tabTo(page, title)
    await page.keyboard.press('ArrowRight')
    await page.keyboard.type(' updated')
    await expect(title).toHaveValue(`${event.title} updated`)
    if (width < 1024) await page.getByRole('button', { name: 'Event navigation' }).click()
    const ticketLink = page.getByRole('navigation', { name: 'Event workspace' }).getByRole('link', { name: 'Ticket types' })
    await tabTo(page, ticketLink)
    await page.keyboard.press('Enter')
    await expect(page.getByRole('region', { name: 'Ticket types' })).toBeFocused()
    await scan(page, 'organizer ticket types')
  })
}

test('sign-in fallback has a clear alert and keyboard-visible focus', async ({ page }) => {
  await prepare(page)
  await page.goto('/sign-in')
  await expect(page.getByRole('alert')).toContainText('unavailable')
  await scan(page, 'sign-in fallback')
  await page.keyboard.press('Tab')
  await expect(page.locator(':focus')).toBeVisible()
})

for (const width of [375, 1440]) {
  test(`order confirmation, receipt, refund request, transfer and ticket QR at ${width}px`, async ({ page }) => {
    test.setTimeout(60_000)
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.route('**/api/v1/config', route => json(route, { launch_capabilities: { ticket_transfers: true } }))
    const order = { id: 99, reference: 'HP-99', status: 'completed', buyer_name: 'Mina', buyer_email: 'mina@example.invalid',
      total_cents: 2000, subtotal_cents: 2000, service_fee_cents: 0, completed_at: '2026-10-20T08:00:00Z',
      order_items: [{ id: 1, name: 'Admission', quantity: 1, subtotal_cents: 2000 }],
      tickets: [{ id: 7, status: 'issued', admission_allowed: true, refundable_cents: 2000,
        display_credential: 'display-7', ticket_type: { id: 10, name: 'Admission' } }],
      latest_event_change: { id: 4, change_type: 'rescheduled', reason: 'The venue changed its schedule.' },
      event: { ...event, transfers_enabled: true },
    }
    await page.route('**/api/v1/orders/99', route => json(route, order))
    await page.route('**/api/v1/orders/99/receipt', route => route.fulfill({ status: 200,
      contentType: 'application/pdf', body: '%PDF-1.4\n%%EOF' }))
    await page.route('**/api/v1/orders/99/event_change_response', route => json(route, { status: 'requested' }))
    await page.route('**/api/v1/orders/99/tickets/7/transfer', route => json(route, { status: 'pending' }))
    await page.route('**/api/v1/tickets/display-7', route => json(route, { id: 7, status: 'issued',
      admission_allowed: true, scan_credential: 'synthetic-scan-7', wallet: {},
      event: order.event, ticket_type: { name: 'Admission' } }))
    await page.goto('/orders/99/confirmation')
    await expect(page.getByRole('heading', { level: 1, name: /confirmed/i })).toBeVisible()
    await scan(page, 'order confirmation')
    const receipt = page.getByRole('button', { name: 'Download Receipt' })
    await tabTo(page, receipt)
    const download = page.waitForEvent('download')
    await page.keyboard.press('Enter')
    expect((await download).suggestedFilename()).toBe('hafapass-receipt-HP-99.pdf')
    const refund = page.getByRole('button', { name: 'Request refund' })
    await tabTo(page, refund)
    await page.keyboard.press('Enter')
    await expect(page.getByRole('status').filter({ hasText: /refund/i }).first()).toBeVisible()
    const transfer = page.getByRole('button', { name: 'Transfer', exact: true })
    await tabTo(page, transfer)
    await page.keyboard.press('Enter')
    const dialog = page.getByRole('dialog')
    await expect(dialog).toBeVisible()
    await scan(page, 'transfer ticket dialog')
    await expect(dialog.getByLabel('Recipient email')).toBeFocused()
    await page.keyboard.type('friend@example.invalid')
    await tabTo(page, dialog.getByRole('button', { name: 'Send transfer' }))
    await page.keyboard.press('Enter')
    await expect(dialog.getByRole('heading', { name: /transfer sent/i })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    const openTicket = page.getByRole('link', { name: 'Open ticket: Admission' })
    await tabTo(page, openTicket)
    await page.keyboard.press('Enter')
    await expect(page.getByRole('img', { name: 'Ticket entry QR code' })).toBeVisible()
    await scan(page, 'ticket QR view')
  })
}

for (const width of [375, 1440]) {
  test(`My Tickets, tab navigation and transfer at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.route('**/api/v1/config', route => json(route, { launch_capabilities: { ticket_transfers: true } }))
    const ticket = { id: 7, order_id: 99, status: 'issued', display_credential: 'display-7',
      attendee_name: 'Mina Cruz', ticket_type: { name: 'Admission' },
      event: { ...event, transfers_enabled: true } }
    await page.route('**/api/v1/me/tickets?**', route => json(route, { tickets: [ticket], meta: { current_page: 1, total_pages: 1 } }))
    await page.route('**/api/v1/me/orders?**', route => json(route, { orders: [], meta: {} }))
    await page.route('**/api/v1/me/tickets/7/transfer', route => json(route, { status: 'pending' }))
    await page.goto('/my-tickets')
    await expect(page.getByText(event.title).first()).toBeVisible()
    await scan(page, 'My Tickets')
    const ordersTab = page.getByRole('tab', { name: 'Orders' })
    await tabTo(page, page.getByRole('tab', { name: 'Tickets' }))
    await page.keyboard.press('ArrowRight')
    await expect(ordersTab).toBeFocused()
    await expect(page.getByRole('tabpanel', { name: 'Orders' })).toBeVisible()
    await page.keyboard.press('ArrowLeft')
    await expect(page.getByRole('tab', { name: 'Tickets' })).toBeFocused()
    const transfer = page.getByRole('button', { name: 'Transfer', exact: true })
    await tabTo(page, transfer)
    await page.keyboard.press('Enter')
    const dialog = page.getByRole('dialog')
    await expect(dialog).toBeVisible()
    await scan(page, 'My Tickets transfer')
    await page.keyboard.press('Escape')
    await expect(transfer).toBeFocused()
  })
}

for (const width of [375, 1440]) {
  test(`organizer create event, attendee filters and export at ${width}px`, async ({ page }) => {
    test.setTimeout(60_000)
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.route('**/api/v1/organizer/organization', route => json(route, { id: 1, name: 'Island Events',
      permissions: { manage_events: true } }))
    await page.route('**/api/v1/organizer/events/601/attendees?**', route => json(route, {
      attendees: [{ id: 7, attendee_name: 'Mina Cruz', attendee_email: 'mina@example.invalid',
        order_number: 'HP-99', ticket_type: 'Admission', status: 'issued' }],
      meta: { total_count: 1, total_pages: 1 },
    }))
    await page.route('**/api/v1/organizer/events/601/sales_exports', route => {
      if (route.request().method() !== 'POST') return json(route, { exports: [] })
      return route.fulfill({ status: 200, contentType: 'text/csv',
        headers: { 'Content-Disposition': 'attachment; filename="attendees.csv"' },
        body: 'Name,Order #\nMina Cruz,HP-99\n' })
    })
    await page.goto('/dashboard/events/new')
    await expect(page.getByRole('heading', { level: 1, name: 'Create New Event' })).toBeVisible()
    await scan(page, 'organizer create event')
    const create = page.getByRole('button', { name: 'Create Event', exact: true })
    await tabTo(page, create)
    await page.keyboard.press('Enter')
    await expect(page.getByLabel(/Event Title/)).toBeFocused()
    await page.goto('/dashboard/events/601/attendees')
    await expect(page.getByRole('status').filter({ hasText: '1 attendee' })).toBeVisible()
    await scan(page, 'attendees list')
    const filters = page.getByRole('button', { name: 'Filters & sort' })
    await tabTo(page, filters)
    await page.keyboard.press('Enter')
    await scan(page, 'attendee filters')
    const channel = page.getByRole('combobox', { name: 'Sales channel' })
    await tabTo(page, channel)
    await channel.press('b')
    await expect(channel).toHaveValue('box_office')
    await tabTo(page, page.getByRole('button', { name: 'Show results' }))
    await page.keyboard.press('Enter')
    await expect(page).toHaveURL(/channel=box_office/)
    const exportButton = page.getByRole('button', { name: 'Export this list' })
    await tabTo(page, exportButton)
    await page.keyboard.press('Enter')
    const dialog = page.getByRole('dialog', { name: 'Export this list' })
    await expect(dialog).toBeVisible()
    await scan(page, 'attendee export dialog')
    const download = page.waitForEvent('download')
    await tabTo(page, dialog.getByRole('button', { name: 'Download CSV' }))
    await page.keyboard.press('Enter')
    expect((await download).suggestedFilename()).toContain('attendees.csv')
  })
}

for (const width of [375, 1440]) {
  test(`organizer box office sale and cancel refund dialog at ${width}px`, async ({ page }) => {
    test.setTimeout(60_000)
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    const doorEvent = { ...organizerEvent, status: 'published', ticket_types: [{ ...event.ticket_types[0],
      quantity_available: 20, quantity_sold: 0, door_allocation: 10, door_sold_quantity: 0, door_available_quantity: 10 }] }
    await page.route('**/api/v1/organizer/events/601', route => json(route, doorEvent))
    await page.route('**/api/v1/organizer/card_present_account', route => json(route, { status: 'unavailable', payment_ready: false }))
    await page.route('**/api/v1/organizer/events/601/box_office/summary', route => json(route,
      { total_orders: 0, total_tickets: 0, total_revenue_cents: 0, by_payment_method: {} }))
    await page.route('**/api/v1/organizer/events/601/box_office', route => json(route, {
      id: 99, status: 'completed', buyer_name: 'Mina Cruz', buyer_email: 'mina@example.invalid',
      total_cents: 2000, source: 'box_office', payment_method: 'door_cash',
      tickets: [{ id: 7, scan_credential: 'test-credential', ticket_type: { name: 'Admission' } }],
    }, 201))
    await page.route('**/api/v1/organizer/events/601/cancellation_refunds?**', route => json(route,
      { preview: { count: 1, total_cents: 2000, cash_count: 1 }, run: null }))
    await page.goto('/dashboard/events/601/box-office')
    await expect(page.getByRole('heading', { name: 'Box Office' })).toBeVisible()
    await scan(page, 'box office')
    const add = page.getByRole('button', { name: 'Add Admission' })
    await tabTo(page, add)
    await page.keyboard.press('Enter')
    const sale = page.getByRole('button', { name: /Process Sale/ })
    await tabTo(page, sale)
    await page.keyboard.press('Enter')
    await expect(page.getByText('Sale Complete!')).toBeVisible()
    await scan(page, 'box office sale result')
    await page.goto('/dashboard/events/601/edit')
    const review = page.locator('button[aria-controls="cancellation-refund-progress"]')
    await expect(review).toHaveText('Review cancellation and refunds')
    await tabTo(page, review)
    await page.keyboard.press('Enter')
    await expect(page.getByText('1 order · $20.00 including service fees.')).toBeVisible()
    const cancel = page.getByRole('button', { name: 'Cancel event and refund all buyers' })
    await tabTo(page, cancel)
    await page.keyboard.press('Enter')
    const dialog = page.getByRole('dialog', { name: 'Cancel event and refund all buyers?' })
    await expect(dialog).toBeVisible()
    await scan(page, 'cancel and refund dialog')
    await tabTo(page, dialog.getByRole('textbox', { name: 'Reason for cancellation' }))
    await page.keyboard.type('Event cannot proceed')
    const confirm = dialog.getByRole('button', { name: 'Confirm cancellation and refunds' })
    await expect(confirm).toBeEnabled()
    await tabTo(page, confirm)
    await page.keyboard.press('Tab')
    expect(await dialog.evaluate(element => element.contains(document.activeElement))).toBe(true)
    await page.keyboard.press('Escape')
    await expect(cancel).toBeFocused()
  })
}

for (const width of [375, 1440]) {
  test(`scanner manual check-in at ${width}px`, async ({ page }) => {
    test.setTimeout(60_000)
    await page.setViewportSize({ width, height: 900 })
    await prepare(page)
    await page.route('**/api/v1/me', route => json(route, { id: 7, role: 'organizer' }))
    await page.route(/\/api\/v1\/organizer\/events(?:\?.*)?$/, route => json(route,
      { events: [{ id: 42, title: 'Accessible Community Night', status: 'published' }], meta: {} }))
    const device = { id: 8, identifier: 'a11y-test', name: 'North door', effective: true,
      status: 'active', authorization_expires_at: new Date(Date.now() + 86_400_000).toISOString(),
      last_sequence: 0, user: { id: 7, name: 'Door Staff' } }
    await page.route('**/api/v1/organizer/events/42/scanner_devices', route => json(route, device, 201))
    await page.route('**/api/v1/organizer/events/42/scanner_devices/8/manifest', route => json(route, scannerManifest()))
    await page.route('**/api/v1/organizer/events/42/admissions', route => json(route,
      { counts: { admitted: 0, remaining: 1, conflicts: 0, rejected: 0 }, devices: [device],
        recent_actions: [], permissions: { can_reverse: true } }))
    await page.route('**/api/v1/organizer/events/42/scanner_devices/8/sync', route => json(route,
      { results: [{ result: 'accepted', reason_code: 'admitted', attendee: {} }],
        device: { ...device, last_sequence: 1 }, summary: { admitted: 1, remaining: 0, conflicts: 0, rejected: 0 } }))
    await page.goto('/dashboard/scanner?event=42#manual-ticket-entry')
    await expect(page.getByText('Device details')).toBeVisible()
    await expect(page.getByLabel('Ticket QR code')).toBeEnabled()
    await scan(page, 'scanner')
    const code = page.getByLabel('Ticket QR code')
    await tabTo(page, code)
    await page.keyboard.type('scan-test-7')
    await tabTo(page, page.getByRole('button', { name: 'Check ticket' }))
    await page.keyboard.press('Enter')
    await expect(page.getByText(/Admitted/).first()).toBeVisible()
    await scan(page, 'scanner admission result')
  })
}
