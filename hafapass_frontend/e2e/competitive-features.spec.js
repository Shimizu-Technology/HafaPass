import { expect, test } from '@playwright/test'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })

test('buyer completes an organizer-absorbed checkout with an add-on, registration answer, and waiver snapshot', async ({ page }) => {
  const startsAt = new Date(Date.now() + 7 * 86400_000).toISOString()
  const event = {
    id: 42, slug: 'island-festival', title: 'Island Festival', description: 'A community celebration',
    status: 'published', starts_at: startsAt, ends_at: new Date(Date.now() + 7 * 86400_000 + 10800_000).toISOString(),
    timezone: 'Pacific/Guam', venue_name: 'Ypao Beach', venue_address: 'Tumon', purchasable: true,
    fee_policy: 'organizer_absorbs', buyer_fee_percent: 0, transfers_enabled: true,
    ticket_types: [{ id: 7, name: 'General Admission', price_cents: 2000, current_price_cents: 2000,
      quantity_available: 20, quantity_sold: 0, quantity_remaining: 20, on_sale: true, max_per_order: 10 }],
    catalog_items: [{ id: 8, name: 'Festival shirt', description: 'Pickup at the welcome table', kind: 'merchandise',
      price_cents: 2500, quantity_remaining: 10 }],
    registration_questions: [{ id: 9, prompt: 'Meal preference?', kind: 'short_text', required: true, options: [] }],
    waivers: [{ id: 10, title: 'Participation waiver', body: 'Follow venue and safety rules.', version: '2.0', required: true }],
    organizer: { business_name: 'Island Events', verified: true }, attendee_count: 0, attendees_preview: [],
  }
  let submitted
  const completedOrder = {
    id: 99, reference: 'HP-PHASE8', status: 'completed', buyer_email: 'buyer@example.com', buyer_name: 'Guam Buyer',
    subtotal_cents: 4500, service_fee_cents: 0, discount_cents: 0, total_cents: 4500, refunded_cents: 0,
    ticket_access_blocked: false, event, order_items: [{ id: 1, name: 'General Admission', quantity: 1, subtotal_cents: 2000 },
      { id: 2, name: 'Festival shirt', quantity: 1, subtotal_cents: 2500 }], tickets: [],
  }

  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', service_fee_percent: 3,
    service_fee_flat_cents: 50, buyer_terms_version: 'buyer-v1' }))
  await page.route('**/api/v1/events/island-festival', route => json(route, event))
  await page.route('**/api/v1/orders', async route => {
    if (route.request().method() === 'POST') {
      submitted = route.request().postDataJSON()
      return json(route, completedOrder, 201)
    }
    return route.continue()
  })
  await page.route('**/api/v1/orders/99', route => json(route, completedOrder))

  await page.goto('/events/island-festival')
  await page.getByRole('button', { name: 'Increase quantity' }).click()
  await page.getByRole('button', { name: /Buy Tickets/ }).click()
  await page.getByLabel('Full Name').fill('Guam Buyer')
  await page.getByLabel('Email Address').fill('buyer@example.com')
  await page.locator('input[aria-label="Festival shirt quantity"]:visible').fill('1')
  await page.locator('input#question-9:visible').fill('Vegetarian')
  await page.locator('label:visible').filter({ hasText: 'I accept version 2.0' }).click()
  await page.locator('input#termsAccepted:visible').check()
  await page.getByRole('button', { name: /Place Order/ }).click()

  await expect(page.getByRole('heading', { name: 'Your order is confirmed' })).toBeVisible()
  expect(submitted.catalog_items).toEqual([{ catalog_item_id: 8, quantity: 1, amount_cents: null }])
  expect(submitted.registration_answers['9']).toBe('Vegetarian')
  expect(submitted.waiver_acceptances).toEqual([{ event_waiver_id: 10, version: '2.0' }])
})
