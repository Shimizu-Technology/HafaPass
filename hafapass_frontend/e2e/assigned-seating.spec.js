import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })

test('buyer selects an exact seat, holds it, and completes seat-specific checkout', async ({ page }) => {
  const startsAt = new Date(Date.now() + 7 * 86400_000).toISOString()
  const event = {
    id: 77, slug: 'guam-theater', title: 'Guam Theater Night', description: 'Reserved seating show',
    status: 'published', starts_at: startsAt, ends_at: new Date(Date.now() + 7 * 86400_000 + 7200_000).toISOString(),
    timezone: 'Pacific/Guam', venue_name: 'Guam Museum', venue_address: 'Hagåtña', purchasable: true,
    assigned_seating: true, fee_policy: 'organizer_absorbs', buyer_fee_percent: 0, transfers_enabled: true,
    ticket_types: [{ id: 7, name: 'Main reserved', price_cents: 2500, current_price_cents: 2500,
      quantity_available: 20, quantity_sold: 0, quantity_remaining: 20, on_sale: true }],
    catalog_items: [], registration_questions: [], waivers: [], organizer: { business_name: 'Museum Events', verified: true },
    attendee_count: 0, attendees_preview: [],
  }
  const seat = { id: 12, label: '1', display_label: 'Main floor · Row A · Seat 1', price_cents: 2500,
    ticket_type_id: 7, ticket_type_name: 'Main reserved', status: 'available', accessibility_kind: 'standard',
    requires_accessibility_attestation: false, obstructed_view: false }
  let submitted
  const completedOrder = {
    id: 101, reference: 'HP-SEAT', status: 'completed', buyer_email: 'buyer@example.com', buyer_name: 'Seat Buyer',
    subtotal_cents: 2500, service_fee_cents: 0, discount_cents: 0, total_cents: 2500, refunded_cents: 0,
    ticket_access_blocked: false, event, order_items: [{ id: 1, name: 'Main reserved', quantity: 1, subtotal_cents: 2500 }],
    tickets: [{ id: 501, status: 'issued', attendee_name: 'Seat Buyer', display_credential: 'display-token',
      ticket_type: { id: 7, name: 'Main reserved', price_cents: 2500 },
      seat: { id: 12, display_label: seat.display_label, accessibility_kind: 'standard', obstructed_view: false } }],
  }

  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', service_fee_percent: 3,
    service_fee_flat_cents: 50, buyer_terms_version: 'buyer-v1' }))
  await page.route('**/api/v1/events/guam-theater/seating', route => json(route, {
    suspended: false, hold_duration_seconds: 600,
    sections: [{ id: 1, name: 'Main floor', rows: [{ id: 2, label: 'A', seats: [seat] }] }],
  }))
  await page.route('**/api/v1/events/guam-theater/seat_holds', route => json(route, {
    token: 'seat-hold-token', expires_at: new Date(Date.now() + 600_000).toISOString(), event_seats: [seat],
  }, 201))
  await page.route('**/api/v1/events/guam-theater', route => json(route, event))
  await page.route('**/api/v1/orders', async route => {
    submitted = route.request().postDataJSON()
    return json(route, completedOrder, 201)
  })
  await page.route('**/api/v1/orders/101', route => json(route, completedOrder))

  await page.goto('/events/guam-theater')
  const accessibilityResults = await new AxeBuilder({ page }).analyze()
  expect(accessibilityResults.violations.filter(violation => ['serious', 'critical'].includes(violation.impact))).toEqual([])
  const seatButton = page.getByRole('button', { name: /Main floor, row A, seat 1/ })
  await seatButton.focus()
  await page.keyboard.press('Enter')
  await expect(seatButton).toHaveAttribute('aria-pressed', 'true')
  await page.getByRole('button', { name: 'Reserve selected seats' }).click()
  await expect(page.getByText(seat.display_label)).toBeVisible()
  await page.getByLabel('Full Name').fill('Seat Buyer')
  await page.getByLabel('Email Address').fill('buyer@example.com')
  await page.locator('input#termsAccepted:visible').check()
  await page.getByRole('button', { name: /Place Order/ }).click()

  await expect(page.getByRole('heading', { name: 'Your order is confirmed' })).toBeVisible()
  await expect(page.getByText(seat.display_label)).toBeVisible()
  expect(submitted.seat_hold_token).toBe('seat-hold-token')
  expect(submitted.line_items).toEqual([{ ticket_type_id: 7, quantity: 1 }])
})
