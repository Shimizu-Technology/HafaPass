import { expect, test } from '@playwright/test'

// Preview-only demo staff identity: organizer, admin, box-office and door screens
// open with fictional data, no sign-in and no network calls.
const SCREENS = [
  ['/dashboard', /Welcome, Isla Demo Sports League/],
  ['/dashboard/events/101/box-office', /Select tickets/],
  ['/dashboard/scanner?event=101', /Ticket list ready · 6 tickets/],
  ['/admin', /Buyer payments/],
  ['/admin/payouts', /Isla Demo Sports League/],
  ['/dashboard/finances', /Sales, fees and payouts across every Isla Demo Sports League event/],
]

for (const viewport of [{ width: 390, height: 844 }, { width: 1280, height: 900 }]) {
  test.describe(`demo staff screens at ${viewport.width}px`, () => {
    test.use({ viewport })
    for (const [path, expected] of SCREENS) {
      test(`${path} renders fictional data`, async ({ page }) => {
        const problems = []
        page.on('console', message => { if (['error', 'warning'].includes(message.type())) problems.push(message.text()) })
        page.on('pageerror', error => problems.push(error.message))
        page.on('request', request => { if (/onrender\.com|localhost:3000|127\.0\.0\.1:3000|stripe\.com|clerk\./i.test(request.url())) problems.push(request.url()) })
        await page.goto(path)
        await expect(page.getByTestId('demo-preview-banner')).toContainText('fictional data, nothing is saved')
        await expect(page.locator('main')).toContainText(expected)
        expect(problems).toEqual([])
      })
    }
  })
}

test('buyer account pages keep the sign-in-is-off notice', async ({ page }) => {
  await page.goto('/my-tickets')
  await expect(page.getByRole('heading', { name: 'Your tickets in this preview' })).toBeVisible()
})
