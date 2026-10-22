import { test, expect } from '@playwright/test'

test('waitlist unsubscribe presents event and organizer choices', async ({ page }) => {
  await page.route('**/api/v1/health', route => route.fulfill({ json: { status: 'ok' } }))
  await page.route('**/api/v1/config', route => route.fulfill({ json: { payment_mode: 'simulate', launch_capabilities: {} } }))
  await page.route('**/api/v1/marketing/unsubscribe/example-token', async route => {
    if (route.request().method() === 'GET') {
      await route.fulfill({ json: { organization: 'Island Nights', event: 'Friday Show', scope: 'waitlist', unsubscribed: false } })
    } else {
      await route.fulfill({ json: { unsubscribed: true } })
    }
  })
  await page.goto('/unsubscribe/example-token')
  await expect(page.getByRole('button', { name: 'Stop alerts for this event' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Stop all marketing from this organizer' })).toBeVisible()
  await page.getByRole('button', { name: 'Stop alerts for this event' }).click()
  await expect(page.getByText('Alerts for Friday Show have stopped.')).toBeVisible()
})
