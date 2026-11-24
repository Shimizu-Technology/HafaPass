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

test('box office demo completes cash and provides ticket delivery actions', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/dashboard/events/101/box-office')
  await page.getByRole('button', { name: /^Add / }).first().click()
  await page.getByRole('button', { name: /Process sale/ }).click()
  await expect(page.getByText('Sale complete!')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Print tickets' })).toBeVisible()
  await page.getByRole('button', { name: 'Show QR' }).click()
  await expect(page.getByRole('dialog', { name: 'Show QR' }).getByRole('img')).toBeVisible()
  await page.getByRole('button', { name: 'Close', exact: true }).click()
  await page.getByRole('button', { name: 'Email tickets' }).click()
  await page.getByRole('textbox', { name: 'Confirm buyer email' }).fill('player@example.invalid')
  await page.getByRole('button', { name: 'Send tickets' }).click()
  await expect(page.getByText('Ticket email queued for player@example.invalid.')).toBeVisible()
})

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

for (const [mode, control] of [
  ['Pay on buyer’s phone', { role: 'img', name: 'Stripe payment QR' }],
  ['Enter card on this device', { role: 'link', name: 'Open Stripe checkout' }],
]) {
  test(`demo box office simulates ${mode} without Stripe`, async ({ page }) => {
    const external = []
    page.on('request', request => { if (/stripe\.com/.test(request.url())) external.push(request.url()) })
    await page.goto('/dashboard/events/101/box-office')
    await page.getByRole('button', { name: /^Add / }).first().click()
    await page.getByRole('button', { name: mode }).click()
    await page.getByRole('button', { name: 'Prepare Stripe checkout' }).click()
    await expect(page.getByRole('heading', { name: 'Waiting for payment…' })).toBeVisible()
    const checkout = page.getByRole(control.role, { name: control.name })
    await expect(checkout).toBeVisible()
    if (control.role === 'link') await expect(checkout).toHaveAttribute('href', /\/door-payment\?result=finished&demo=1$/)
    await expect(page.getByRole('heading', { name: 'Paid — tickets ready' })).toBeVisible({ timeout: 12_000 })
    expect(external).toEqual([])
  })
}
