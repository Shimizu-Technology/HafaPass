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
    await page.goto('/events/guam-community-night')
    await expect(page.getByRole('heading', { name: event.title })).toBeVisible()
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
