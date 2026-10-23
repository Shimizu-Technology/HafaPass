import { expect, test } from '@playwright/test'

test('opens the public marketplace when backend services are available', async ({ page }) => {
  await page.route('**/api/v1/health', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ status: 'ok' }),
  }))
  await page.route('**/api/v1/events', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ events: [] }),
  }))

  await page.goto('/')

  await expect(page.getByRole('heading', { name: 'Events are coming soon' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'List your event' })).toBeVisible()
})

test('keeps public browsing mounted with a recoverable outage banner when the background health check fails', async ({ page }) => {
  let healthChecks = 0
  await page.route('**/api/v1/health', route => {
    healthChecks += 1
    return route.fulfill({
      status: 503,
      contentType: 'application/json',
      body: JSON.stringify({ status: 'not_ready' }),
    })
  })
  await page.route('**/api/v1/events', route => route.fulfill({ status: 503, contentType: 'application/json', body: '{}' }))
  await page.route('**/api/v1/config', route => route.fulfill({ status: 503, contentType: 'application/json', body: '{}' }))

  // The outage page reuses the last support contact loaded from /config.
  await page.addInitScript(() => window.localStorage.setItem('hafapass_support_contact', JSON.stringify({ email: 'help@example.test', phone: '' })))
  await page.goto('/')

  await expect(page.getByRole('alert').filter({ hasText: 'We’re having trouble reaching HåfaPass' })).toBeVisible()
  await expect(page.getByRole('link', { name: /start hosting/i }).first()).toBeVisible()
  await page.getByRole('button', { name: 'Try again', exact: true }).click()
  await expect.poll(() => healthChecks).toBeGreaterThan(1)
})
