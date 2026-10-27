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
    for (const path of ['/', '/events', '/discover']) {
      await page.goto(path)
      await expect(page.getByRole('heading', { name: 'The first events go on sale soon.' })).toBeVisible()
      const main = page.getByRole('main')
      await expect(main.getByText('Come back soon to find your next night out.')).toBeVisible()
      if (path === '/') {
        await expect(main.getByRole('heading', { level: 1, name: 'Your night out on Guam starts here.' })).toBeVisible()
        await expect(main.getByText('Your event guide on Guam')).toHaveCount(0)
        await expect(main.getByRole('img')).toHaveCount(0)
        await expect(main.getByRole('heading', { name: 'Planning an event?' })).toBeVisible()
        await expect(main.getByRole('link', { name: 'Start Hosting' })).toHaveAttribute('href', '/host')
        await expect(main.getByRole('heading', { name: /^Explore by category$/i })).toHaveCount(0)
        await expect(page.locator('main a[href="/events"]:not(footer a)')).toHaveCount(0)
        await expect(main.getByRole('heading', { name: 'Coming up' })).toHaveCount(0)
      } else {
        await expect(main.getByRole('link', { name: 'Sell tickets' })).toHaveAttribute('href', '/host')
        await expect(main.getByRole('link', { name: 'Back to event guide' })).toHaveCount(0)
        await expect(main.getByRole('heading', { level: 1, name: path === '/events' ? 'Events' : 'Discover', exact: true })).toBeVisible()
      }
      await expect(page.getByRole('main').getByRole('searchbox')).toHaveCount(0)
      await expect(page.getByRole('main').getByRole('combobox')).toHaveCount(0)
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width)
      const results = await new AxeBuilder({ page }).analyze()
      expect(results.violations.filter(v => ['serious', 'critical'].includes(v.impact))).toEqual([])
    }
    for (const query of ['search=music', 'category=concert', 'q=music']) {
      await page.goto(`/events?${query}`)
      await expect(page.getByRole('heading', { name: 'No matching events' })).toBeVisible()
      await expect(page.getByRole('textbox', { name: 'Search events and venues' })).toBeVisible()
      if (query.includes('music')) {
        await expect(page.getByRole('textbox', { name: 'Search events and venues' })).toHaveValue('music')
        await expect(page).toHaveURL(/search=music/)
      }
      const results = await new AxeBuilder({ page }).analyze()
      expect(results.violations.filter(v => ['serious', 'critical'].includes(v.impact))).toEqual([])
      await page.getByRole('button', { name: 'Clear filters' }).click()
      await expect(page.getByRole('heading', { name: 'The first events go on sale soon.' })).toBeVisible()
      await expect(page).toHaveURL(/\/events$/)
    }
    hasEvents = true
    await page.goto('/')
    await expect(page.getByRole('heading', { name: 'Your night out on Guam starts here.' })).toBeVisible()
    await expect(page.getByRole('searchbox', { name: 'Event or venue' })).toBeVisible()
    await expect(page.getByRole('heading', { name: /^Explore by category$/i })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Coming up' })).toBeVisible()
    await expect(page.getByRole('link', { name: /Community night/ })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'The first events go on sale soon.' })).toHaveCount(0)
    await page.goto('/events?search=nothing')
    await expect(page.getByRole('heading', { name: 'No matching events' })).toBeVisible()
    await page.getByRole('button', { name: 'Clear filters' }).click()
    await expect(page.getByRole('link', { name: /Community night/ })).toBeVisible()
    await page.goto('/discover')
    await expect(page.getByRole('link', { name: 'Browse events', exact: true })).toBeVisible()
    await expect(page.getByText('The first events go on sale soon.')).toHaveCount(0)
  })
}

for (const width of [375, 768, 1280]) {
  test(`footer keeps buyer policies visible and all policies reachable at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 812 })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, {}))
    await page.route('**/api/v1/events*', route => json(route, { events: [] }))
    await page.goto('/')
    const footer = page.locator('footer')
    const disclosure = footer.locator('summary').filter({ hasText: 'Other policies' })
    for (const slug of ['privacy', 'buyer-terms', 'refunds']) {
      await expect(footer.locator(`a[href="/policies/${slug}"]:visible`)).toBeVisible()
    }
    if (width < 768) {
      await expect(disclosure).toBeVisible()
      expect((await disclosure.boundingBox()).height).toBeGreaterThanOrEqual(44)
      await expect(disclosure.locator('..')).not.toHaveAttribute('open')
      await expect(footer.locator('a[href="/policies/organizer-agreement"]:visible')).toHaveCount(0)
      await disclosure.focus()
      await page.keyboard.press('Enter')
      await expect(disclosure.locator('..')).toHaveAttribute('open', '')
    } else {
      await expect(disclosure).toBeHidden()
    }
    for (const slug of ['privacy', 'buyer-terms', 'refunds', 'organizer-agreement', 'accessibility', 'cookies']) {
      const link = footer.locator(`a[href="/policies/${slug}"]:visible`)
      await expect(link).toHaveCount(1)
      await expect(link).toBeVisible()
      await link.focus()
      await expect(link).toBeFocused()
      expect((await link.boundingBox()).height).toBeGreaterThanOrEqual(44)
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width)
  })
}
