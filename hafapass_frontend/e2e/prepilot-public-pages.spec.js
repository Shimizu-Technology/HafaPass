import { expect, test } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const json = (route, data) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(data) })
const config = { payment_mode: 'live', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 business days after your event', support_email: 'public-pages-qa@example.test' }

for (const [width, height] of [[375, 812], [768, 1024], [1280, 800]]) {
  test(`public photography, pricing and keyboard credits at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
    await page.route('**/api/v1/config', route => json(route, config))
    await page.route('**/api/v1/events*', route => json(route, { events: [] }))
    await page.goto('/')
    await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toBeVisible()
    const photo = page.getByRole('img', { name: /Orange clouds over Tumon Bay/ })
    await expect(photo).toHaveAttribute('loading', 'eager')
    await expect(photo).toHaveAttribute('width', '1280')
    await expect.poll(() => photo.evaluate(image => image.complete && image.naturalWidth > 0)).toBe(true)
    await expect(photo).toHaveAttribute('srcset', /480w.*800w.*1280w/)
    const credits = page.locator('footer summary').filter({ hasText: 'Photo credits' })
    await credits.focus()
    await page.keyboard.press('Enter')
    for (const link of await page.locator('footer a[href*="commons.wikimedia.org/wiki/File:"]').all()) {
      await link.focus()
      await expect(link).toBeFocused()
      await expect(link).toHaveCSS('outline-style', 'solid')
    }
    await page.goto('/host')
    await expect(page.getByTestId('host-fee-summary')).toContainText('5% + $1.00 per paid ticket')
    const example = page.getByRole('region', { name: '$59.00 ticket' })
    await expect(example).toContainText('$62.95')
    await expect(example).toContainText('$55.05')
    await page.getByLabel('Ticket price', { exact: true }).fill('59')
    await expect(page.getByRole('region', { name: 'Buyer pays the fee', exact: true })).toContainText('$62.95')
    await expect(page.getByRole('region', { name: 'You absorb the fee', exact: true })).toContainText('$55.05')
    await expect(page.getByRole('link', { name: 'Talk to us about your event' })).toHaveAttribute('href', /^mailto:public-pages-qa@example.test/)
    const faq = page.locator('summary').filter({ hasText: 'Does my door staff need an app?' })
    await faq.focus()
    await page.keyboard.press('Enter')
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
      await expect(page.getByRole('heading', { level: 2, name: populated ? 'QA music night' : 'Events are coming soon', exact: true })).toBeVisible()
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
