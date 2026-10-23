import { test, expect } from '@playwright/test'

const slug = 'sold-out-island-show'
const email = 'waitlist-buyer@example.test'
const storageKey = `hafapass:waitlist:${slug}:${email}`

async function prepare(page) {
  await page.route('**/api/v1/health', route => route.fulfill({ json: { status: 'ok' } }))
  await page.route('**/api/v1/config', route => route.fulfill({ json: { payment_mode: 'simulate', launch_capabilities: {} } }))
  await page.route(`**/api/v1/events/${slug}`, route => route.fulfill({ json: {
    id: 901, slug, title: 'Sold-out Island Show', status: 'published', starts_at: '2099-10-11T08:00:00Z',
    timezone: 'Pacific/Guam', venue_name: 'Island Venue', purchasable: true,
    ticket_types: [{ id: 9, name: 'General admission', price_cents: 2000, quantity_available: 10,
      quantity_sold: 10, quantity_remaining: 0, on_sale: true }],
  } }))
  await page.route('**/api/v1/marketplace*', route => route.fulfill({ json: {} }))
  await page.addInitScript(({ storageKey }) => {
    localStorage.setItem(storageKey, JSON.stringify([{ id: 1, token: 'stale-token' }, { id: 2, token: 'valid-token' }]))
  }, { storageKey })
}

for (const width of [375, 1280]) {
  for (const status of [404, 503]) {
    test(`saved waitlist lookup keeps a valid entry beside a ${status} warning at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      await prepare(page)
      let recovered = false
      await page.route(`**/api/v1/events/${slug}/waitlist/status?*`, route => {
        const stale = new URL(route.request().url()).searchParams.get('management_token') === 'stale-token'
        if (stale && !recovered) return route.fulfill({ status, json: { error: 'Unavailable' } })
        return route.fulfill({ json: { entries: [{ id: stale ? 1 : 2, position: stale ? 2 : 7, status: 'offered' }] } })
      })
      await page.goto(`/events/${slug}`)
      await page.getByPlaceholder('Enter your email').fill(email)
      await page.getByRole('button', { name: 'Check', exact: true }).click()
      await expect(page.getByText('#7', { exact: true })).toBeVisible()
      await expect(page.getByText('Ticket offer available', { exact: true })).toBeVisible()
      await expect(page.getByRole('alert')).toContainText(status === 404
        ? 'Some saved waitlist entries are no longer available.'
        : "We couldn't check some saved waitlist entries. Try again.")
      await expect(page.getByText(/No waitlist entries are saved/)).toHaveCount(0)
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
      // Checking status must leave both saved capabilities intact.
      expect(await page.evaluate(key => JSON.parse(localStorage.getItem(key)).length, storageKey)).toBe(2)
      recovered = true
      await page.getByRole('button', { name: 'Check', exact: true }).click()
      await expect(page.getByText('#2', { exact: true })).toBeVisible()
      await expect(page.getByText('#7', { exact: true })).toBeVisible()
      await expect(page.getByRole('alert')).toHaveCount(0)
    })
  }
}
