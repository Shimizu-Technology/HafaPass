import { expect, test } from '@playwright/test'

const json = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const event = {
  id: 601, slug: 'guam-community-night', title: 'Guam Community Night: Music and Food with Our Neighbors',
  description: 'A long event description. '.repeat(70), status: 'published', starts_at: '2099-10-11T08:00:00Z',
  timezone: 'Pacific/Guam', venue_name: 'Community Venue in Tamuning', purchasable: true,
  attendee_count: 10, attendees_preview: ['Ada', 'Ben', 'Cam', 'Dan', 'Eve', 'Fay', 'Gia', 'Hal'], show_attendees: true,
  fee_policy: 'organizer_absorbs', buyer_fee_percent: 0,
  ticket_types: [
    { id: 9, name: 'Earlier free tickets', price_cents: 0, quantity_remaining: 0, on_sale: false },
    { id: 10, name: 'General admission with dinner and entertainment', description: 'Entry, dinner and performances included.',
      price_cents: 2000, current_price_cents: 1250, quantity_remaining: 20, on_sale: true },
  ],
}
async function prepare(page) {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
  await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', service_fee_percent: 0,
    service_fee_flat_cents: 0, buyer_terms_version: 'qa-v1' }))
  await page.route('**/api/v1/events/guam-community-night', route => json(route, event))
  await page.route('**/api/v1/marketplace*', route => json(route, {}))
}

for (const width of [320, 390, 1440]) {
  test(`buyer can select the current ticket and keep its displayed estimate on checkout at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await prepare(page)
    await page.route('https://fonts.googleapis.com/**', route => route.abort())
    await page.route('https://fonts.gstatic.com/**', route => route.abort())
    await page.goto('/events/guam-community-night')
    await expect(page.getByRole('heading', { name: event.title })).toBeVisible()
    await page.evaluate(() => document.fonts.ready)
    expect(await page.evaluate(() => [...document.fonts].some(font => font.family.includes('Plus Jakarta Sans Variable') && font.status === 'loaded'))).toBe(true)
    const layout = await page.evaluate(() => ({
      width: document.documentElement.clientWidth, content: document.documentElement.scrollWidth,
      ticketsTop: document.querySelector('#tickets').getBoundingClientRect().top,
      aboutTop: [...document.querySelectorAll('h2')].find(element => element.textContent === 'About').getBoundingClientRect().top,
    }))
    expect(layout.content).toBeLessThanOrEqual(layout.width)
    if (width < 1024) expect(layout.ticketsTop).toBeLessThan(layout.aboutTop)
    await page.getByRole('button', { name: 'Increase quantity for General admission with dinner and entertainment', exact: true }).click()
    await expect(page.getByRole('button', { name: /Buy Tickets/ })).toContainText('$12.50')
    await page.getByRole('button', { name: /Buy Tickets/ }).click()
    await expect(page).toHaveURL(/\/checkout\/guam-community-night$/)
    await expect(page.getByLabel('Full Name')).toBeVisible()
    await expect(page.getByText('General admission with dinner and entertainment', { exact: true })).toBeVisible()
    await expect(page.getByText('$12.50', { exact: true }).first()).toBeVisible()
  })
}

test('buyer-pays prices are all-in from the first display through the checkout total', async ({ page }) => {
  await prepare(page)
  const allIn = { ...event, fee_policy: 'buyer_pays', buyer_fee_percent: 100, service_fee_includes_processing: true,
    seller: { seller_name: 'Island Nights', ticketing_service: 'HåfaPass', line: 'Sold by Island Nights · Tickets by HåfaPass' },
    ticket_types: [{ id: 10, name: 'General admission with dinner and entertainment', price_cents: 1999, current_price_cents: 1999,
      all_in_price_cents: 2199, service_fee_cents: 200, quantity_remaining: 20, on_sale: true }] }
  await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', service_fee_percent: 5,
    service_fee_flat_cents: 100, processing_fee_bearer: 'platform', buyer_terms_version: 'qa-v1' }))
  await page.route('**/api/v1/events/guam-community-night', route => json(route, allIn))
  await page.goto('/events/guam-community-night')
  const tickets = page.locator('#tickets')
  await expect(tickets.getByText('$21.99', { exact: true })).toBeVisible()
  await expect(tickets.getByText('$19.99 ticket + $2.00 service fee')).toBeVisible()
  await expect(tickets.getByText('Sold by Island Nights · Tickets by HåfaPass')).toBeVisible()
  await tickets.getByRole('button', { name: 'Increase quantity for General admission with dinner and entertainment', exact: true }).click()
  await tickets.getByRole('button', { name: 'Increase quantity for General admission with dinner and entertainment', exact: true }).click()
  await expect(tickets.getByRole('button', { name: /Buy Tickets/ })).toContainText('$43.98')
  await tickets.getByRole('button', { name: /Buy Tickets/ }).click()
  await expect(page).toHaveURL(/\/checkout\/guam-community-night$/)
  await expect(page.getByText('$4.00', { exact: true })).toBeVisible()
  await expect(page.getByText('$43.98', { exact: true }).first()).toBeVisible()
})

test('an event outage retries in place instead of pretending the event is missing', async ({ page }) => {
  await prepare(page)
  let requests = 0
  let restored = false
  await page.route('**/api/v1/events/guam-community-night', route => {
    requests += 1
    return !restored ? json(route, { error: 'Synthetic outage' }, 503) : json(route, event)
  })
  await page.goto('/events/guam-community-night')
  await expect(page.getByRole('alert')).toContainText('couldn’t load')
  const failedRequests = requests
  restored = true
  await page.getByRole('button', { name: 'Retry event', exact: true }).click()
  await expect(page.getByRole('heading', { name: event.title })).toBeVisible()
  expect(requests).toBeGreaterThan(failedRequests)
  await expect(page).toHaveURL(/\/events\/guam-community-night$/)
})


test('opening an event preserves filters without rewriting the event URL from an exiting listing', async ({ page }) => {
  await prepare(page)
  await page.route('**/api/v1/event_categories', route => json(route, { categories: [] }))
  await page.route('**/api/v1/events**', route => new URL(route.request().url()).pathname === '/api/v1/events'
    ? json(route, { events: [event], meta: { current_page: 1, total_pages: 1, total_count: 1 } }) : route.fallback())
  await page.goto('/events?search=Music')
  await page.getByRole('link', { name: /Guam Community Night/ }).click()
  await expect(page).toHaveURL(/\/events\/guam-community-night$/)
  const back = page.getByRole('link', { name: 'All Events', exact: true })
  await expect(back).toHaveAttribute('href', '/events?search=Music')
  await back.click()
  await expect(page.getByRole('textbox', { name: 'Search events and venues' })).toHaveValue('Music')
})
