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

  await expect(page.getByRole('heading', { name: /Guam's Event Scene is About to Take Off/i })).toBeVisible()
  await expect(page.getByRole('link', { name: /start hosting/i }).first()).toBeVisible()
})

test('fails safely into private preview when backend services are unavailable', async ({ page }) => {
  let healthChecks = 0
  await page.route('**/api/v1/health', route => {
    healthChecks += 1
    return route.fulfill({
      status: 503,
      contentType: 'application/json',
      body: JSON.stringify({ status: 'not_ready' }),
    })
  })

  await page.goto('/')

  await expect(page.getByRole('heading', { name: /A better way to run events on Guam is still coming/i })).toBeVisible()
  await page.getByRole('button', { name: /check services again/i }).click()
  await expect.poll(() => healthChecks).toBeGreaterThan(1)
})
