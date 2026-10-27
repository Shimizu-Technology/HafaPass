import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, data) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(data) })
const config = { payment_mode: 'live', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 business days after your event', support_email: 'public-pages-qa@example.test' }

for (const [width, height] of [[375, 812], [768, 1024], [1280, 800]]) {
  test(`pending inventory preserves hosting and policy navigation at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, config))
    await page.route('**/api/v1/events*', () => {}) // Deliberately leave inventory pending.
    await page.goto('/')
    await expect(page.getByRole('status').filter({ hasText: 'Loading upcoming events' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toHaveCount(0)
    await expect(page.locator('a.btn-secondary').filter({ hasText: 'Browse Events' })).toHaveAttribute('href', '/events')
    const footer = page.locator('footer')
    if (width < 768) {
      const policies = footer.locator('summary').filter({ hasText: 'Other policies' })
      await policies.focus()
      await page.keyboard.press('Enter')
      await expect(policies.locator('..')).toHaveAttribute('open', '')
    }
    for (const policy of ['privacy', 'buyer-terms', 'refunds', 'organizer-agreement', 'accessibility', 'cookies']) {
      await expect(footer.locator(`a[href="/policies/${policy}"]:visible`)).toBeVisible()
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false)
    const host = page.getByRole('link', { name: 'Sell tickets', exact: true })
    await host.focus()
    await page.keyboard.press('Enter')
    await expect(page.getByRole('heading', { level: 1, name: 'Host your event with HåfaPass' })).toBeVisible()
    await page.goto('/')
    await footer.locator('a[href="/policies/privacy"]').click()
    await expect(page).toHaveURL(/\/policies\/privacy$/)
  })

  test(`public ticket, pricing and keyboard navigation at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, config))
    await page.route('**/api/v1/events*', route => json(route, { events: [] }))
    await page.goto('/')
    await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toBeVisible()
    await expect(page.locator('main img')).toHaveCount(0)
    await expect(page.locator('footer summary').filter({ hasText: 'Photo credits' })).toHaveCount(0)
    const hosting = page.getByRole('link', { name: 'Sell tickets', exact: true })
    await hosting.focus()
    await expect(hosting).toBeFocused()
    await expect(hosting).toHaveCSS('outline-style', 'solid')
    await page.goto('/host')
    await expect(page.getByTestId('host-fee-summary')).toContainText('5% + $1.00 per paid ticket')
    const pick = page.getByRole('button', { name: '$59', exact: true })
    await pick.focus()
    await expect(pick).toBeFocused()
    await expect(pick).not.toHaveCSS('box-shadow', 'none')
    await page.keyboard.press('Enter')
    await expect(pick).toHaveAttribute('aria-pressed', 'true')
    await expect(page.getByLabel('Ticket price', { exact: true })).toHaveValue('59')
    await expect(page.getByRole('region', { name: 'Buyer pays the fee', exact: true })).toContainText('$62.95')
    await expect(page.getByRole('region', { name: 'You absorb the fee', exact: true })).toContainText('$55.05')
    await expect(page.getByRole('link', { name: 'Talk to us about your event' })).toHaveAttribute('href', /^mailto:public-pages-qa@example.test/)
    const faq = page.locator('summary').filter({ hasText: 'Does my door staff need an app?' })
    await faq.focus()
    await page.keyboard.press('Enter')
    await expect(faq.locator('..')).toHaveAttribute('open', '')
    await expect(faq.locator('..')).toContainText('Each device must be prepared online before the event.')
    const audit = await new AxeBuilder({ page }).include('main').withTags(['wcag2a', 'wcag2aa']).analyze()
    expect(audit.violations).toEqual([])
    expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false)
  })

  test(`delayed inventory and pricing keep layout stable at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.addInitScript(() => {
      window.publicPageCLS = 0
      new PerformanceObserver(list => {
        for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.publicPageCLS += entry.value
      }).observe({ type: 'layout-shift', buffered: true })
    })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', async route => {
      await new Promise(resolve => setTimeout(resolve, 200))
      return json(route, config)
    })
    let events = []
    await page.route('**/api/v1/events*', async route => {
      await new Promise(resolve => setTimeout(resolve, 200))
      return json(route, { events })
    })
    for (const populated of [false, true]) {
      events = populated ? [{ id: 1, slug: 'qa-music-night', title: 'QA music night', is_featured: true, starts_at: '2099-10-11T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }] : []
      await page.goto('/')
      await expect(page.getByRole('heading', { name: populated ? 'QA music night' : 'Events are coming soon', exact: true })).toBeVisible()
      if (populated) {
        const card = page.getByRole('link', { name: /QA music night/ })
        await expect(card.locator('img')).toHaveCount(0)
        await expect(card.locator('[class*="aspect-"]')).toHaveCount(0)
        await expect(card.getByLabel('Sunday, Oct 11, 2099')).toContainText('11')
        await expect(page.locator('time[datetime="2099-10-11T08:00:00Z"]')).toHaveCount(1)
      }
      await page.evaluate(() => document.fonts.ready)
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
      expect(await page.evaluate(() => window.publicPageCLS)).toBeLessThan(0.1)
    }
    await page.goto('/host')
    await expect(page.getByTestId('host-fee-summary')).toBeVisible()
    await page.evaluate(() => document.fonts.ready)
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    expect(await page.evaluate(() => window.publicPageCLS)).toBeLessThan(0.1)
  })

}
