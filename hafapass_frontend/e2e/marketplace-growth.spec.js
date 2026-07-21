import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const startsAt = new Date(Date.now() + 2 * 86400_000).toISOString()
const event = {
  id: 42, title: 'Family Night Market', slug: 'family-night-market', short_description: 'Food and fun',
  starts_at: startsAt, ends_at: new Date(Date.now() + 2 * 86400_000 + 7200_000).toISOString(), timezone: 'Pacific/Guam',
  category: 'family', category_label: 'Family', venue_name: 'Guam Museum', venue_city: 'Hagåtña', purchasable: true,
  organizer: { name: 'Island Events', slug: 'island-events', verified: true },
  ticket_types: [{ id: 3, name: 'Entry', price_cents: 2000, current_price_cents: 2000, quantity_remaining: 10, on_sale: true }],
}

test('buyer discovers a governed collection and filters Guam inventory', async ({ page }) => {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/marketplace_collections', route => json(route, { collections: [{ id: 1, title: 'Family Weekend', slug: 'family-weekend', description: 'Kid-friendly Guam picks', events: [event] }] }))
  await page.route('**/api/v1/events**', route => json(route, { events: [event], meta: { current_page: 1, total_pages: 1, total_count: 1 } }))

  await page.goto('/discover')
  await expect(page.getByRole('heading', { name: 'Family Weekend' })).toBeVisible()
  await expect(page.getByRole('link', { name: /Family Night Market/ })).toBeVisible()
  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations.filter(item => ['serious', 'critical'].includes(item.impact))).toEqual([])

  await page.goto('/events')
  await page.getByLabel('Price').selectOption('under_25')
  await page.getByLabel('Village').selectOption('Hagåtña')
  await expect(page).toHaveURL(/price=under_25/)
  await expect(page).toHaveURL(/village=Hag/)
})

test('partner link records anonymous attribution and opens the intended event', async ({ page }) => {
  let anonymousId
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/distribution_links/GUAM123**', route => {
    anonymousId = new URL(route.request().url()).searchParams.get('anonymous_id')
    return json(route, { event_slug: event.slug, attribution: { distribution_code: 'GUAM123', source: 'hotel', medium: 'partner', campaign: 'front-desk' } })
  })
  await page.route('**/api/v1/events/family-night-market**', route => json(route, { ...event, description: 'Food and fun', status: 'published', venue_address: 'Hagåtña', attendee_count: 0, attendees_preview: [], organizer: { id: 5, business_name: 'Island Events', slug: 'island-events', verified: true, followed: false } }))
  await page.route('**/api/v1/marketplace_funnel_events', route => json(route, {}, 201))

  await page.goto('/go/GUAM123')
  await expect(page).toHaveURL(/events\/family-night-market/)
  await expect(page.getByRole('heading', { name: 'Family Night Market' })).toBeVisible()
  expect(anonymousId).toMatch(/^[a-f0-9-]{36}$/)
  const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('hafapass_attribution')))
  expect(stored).toMatchObject({ distribution_code: 'GUAM123', source: 'hotel', campaign: 'front-desk' })
})
