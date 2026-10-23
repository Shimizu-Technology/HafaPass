import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, body) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) })
const event = { id: 1, slug: 'community-night', title: 'Community night', starts_at: '2099-10-11T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }

for (const width of [375, 1280]) {
  test(`empty inventory leads to hosting and automatically restores browsing at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 812 })
    await page.emulateMedia({ reducedMotion: 'reduce' })
    let hasEvents = false
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, { payment_mode: 'simulate', service_fee_percent: 0, service_fee_flat_cents: 0 }))
    await page.route('**/api/v1/event_categories', route => json(route, { categories: [] }))
    await page.route('**/api/v1/marketplace_collections', route => json(route, { collections: [] }))
    await page.route('**/api/v1/events*', route => {
      const filtered = new URL(route.request().url()).searchParams.has('q')
      const events = hasEvents && !filtered ? [event] : []
      return json(route, { events, meta: { total_count: events.length, total_pages: 1, current_page: 1 } })
    })
    for (const path of ['/', '/events', '/events?search=music', '/discover']) {
      await page.goto(path)
      await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toBeVisible()
      await expect(page.getByRole('link', { name: 'List your event' })).toHaveAttribute('href', '/host')
      await expect(page.getByRole('main').getByRole('searchbox')).toHaveCount(0)
      await expect(page.getByRole('main').getByRole('combobox')).toHaveCount(0)
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width)
      const results = await new AxeBuilder({ page }).analyze()
      expect(results.violations.filter(v => ['serious', 'critical'].includes(v.impact))).toEqual([])
    }
    const policies = page.locator('footer details')
    await policies.locator('summary').focus()
    await page.keyboard.press('Enter')
    await expect(policies.getByRole('link')).toHaveCount(6)
    for (const link of await policies.getByRole('link').all()) await expect(link).toBeVisible()

    hasEvents = true
    await page.goto('/')
    await expect(page.getByRole('heading', { name: 'Find your next event on Guam' })).toBeVisible()
    await expect(page.getByRole('searchbox', { name: 'Event or venue' })).toBeVisible()
    await page.goto('/events?search=nothing')
    await expect(page.getByRole('heading', { name: 'No matching events' })).toBeVisible()
    await page.getByRole('button', { name: 'Clear filters' }).click()
    await expect(page.getByRole('link', { name: /Community night/ })).toBeVisible()
    await page.goto('/discover')
    await expect(page.getByRole('link', { name: 'Browse events', exact: true })).toBeVisible()
    await expect(page.getByText('Events are coming soon')).toHaveCount(0)
  })
}
