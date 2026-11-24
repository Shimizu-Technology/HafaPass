import { expect, test } from '@playwright/test'


test.describe('preview-only demo-data mode', () => {

  test('events list -> event detail -> checkout shows payments-off notice without external API or Stripe calls', async ({ page }) => {
    const blockedRequests = []
    const consoleErrors = []
    const pageErrors = []

    page.on('request', request => {
      const url = request.url()
      if (/hafapass-api\.onrender\.com|localhost:3000|127\.0\.0\.1:3000|stripe\.com|clerk\./i.test(url)) {
        blockedRequests.push(url)
      }
    })
    page.on('console', message => {
      if (message.type() === 'error') consoleErrors.push(message.text())
    })
    page.on('pageerror', error => pageErrors.push(error.message))

    // 1. Events list shows demo banner and Copa de Marianas 2027 (demo)
    await page.goto('/events')
    await expect(page.getByTestId('demo-preview-banner')).toContainText('Demo preview · fictional data')
    await expect(page.getByRole('heading', { name: 'Copa de Marianas 2027 (demo)' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'FD Alumni Basketball Tournament — Night 1 (demo)' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Tumon Bay Acoustic Sessions (demo)' })).toBeVisible()

    // 2. Event detail shows tiers, all-in pricing, selling fast, and sold out
    await page.getByRole('link', { name: /Copa de Marianas 2027 \(demo\)/i }).click()
    await expect(page).toHaveURL(/\/events\/copa-de-marianas-2027/)
    await expect(page.getByRole('heading', { level: 1, name: 'Copa de Marianas 2027 (demo)' })).toBeVisible()
    await expect(page.getByText('UOG Calvo Field House').first()).toBeVisible()
    await expect(page.getByText('$16.75').first()).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Adult Spectator', exact: true })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Youth Spectator (Ages 5–17)', exact: true })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Child Under 5', exact: true })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Ringside Table Seat', exact: true })).toBeVisible()

    // 3. Select 1 Adult Spectator ticket and proceed to checkout
    await page.getByRole('button', { name: /increase quantity for adult spectator/i }).click()
    await page.getByRole('button', { name: /buy tickets/i }).click()

    // 4. Checkout shows clear payments-off notice and never loads Stripe
    await expect(page).toHaveURL(/\/checkout\/copa-de-marianas-2027/)
    await expect(page.getByTestId('demo-payments-off-notice')).toContainText('Demo preview: payments are off')
    await expect(page.locator('iframe[src*="stripe"]')).toHaveCount(0)

    // 5. Sample order confirmation & sample ticket with QR code work cleanly
    await page.getByRole('link', { name: 'View sample confirmation' }).click()
    await expect(page).toHaveURL(/\/orders\/demo-copa-2027\/confirmation/)
    await expect(page.getByText('HP-DEMO-COPA27')).toBeVisible()
    await page.getByRole('link', { name: /open ticket/i }).first().click()
    await expect(page).toHaveURL(/\/tickets\/demo-ticket-copa-adult-1/)
    await expect(page.getByText('Avery Lindqvist', { exact: true })).toBeVisible()
    await expect(page.locator('svg').first()).toBeVisible()

    expect(blockedRequests).toEqual([])
    expect(pageErrors).toEqual([])
    expect(consoleErrors).toEqual([])
  })

  test('renders multi-day pass, sold-out waitlist, pre-launch, and organizer pages', async ({ page }) => {
    await page.goto('/events/fd-alumni-basketball-night-1')
    await expect(page.getByRole('heading', { name: '2-Night Tournament Pass', exact: true })).toBeVisible()
    await page.getByRole('button', { name: /view included nights/i }).click()
    await expect(page.getByText('FD Alumni Basketball Tournament — Night 2 Finals (demo)')).toBeVisible()

    await page.goto('/events/tumon-bay-acoustic-sessions')
    await expect(page.getByRole('heading', { level: 1, name: 'Tumon Bay Acoustic Sessions (demo)' })).toBeVisible()
    await expect(page.getByText(/join.*waitlist/i).first()).toBeVisible()

    await page.goto('/events/guam-night-market-spring-preview')
    await expect(page.getByRole('heading', { level: 1, name: /Guam Night Market/i })).toBeVisible()
    await expect(page.getByText(/Early Bird Entry/i).first()).toBeVisible()

    await page.goto('/organizers/fd-alumni-sports-committee-demo')
    await expect(page.getByRole('heading', { level: 1, name: 'FD Alumni Sports Committee (demo)' })).toBeVisible()
  })
})
