import { expect, test } from '@playwright/test'
import { prepare } from '../scripts/qa/buyer-pages-fixtures.mjs'
import { prepareRound2, verifySelect, verifyCardRows, openCheckout, verifyCheckout } from '../scripts/qa/audit-round-2-fixtures.mjs'

test('guest header offers ticket recovery and optional account creation at 1024', async ({ page }) => {
  await page.setViewportSize({ width: 1024, height: 768 })
  await prepare(page)
  await page.goto('/events')
  const nav = page.getByRole('navigation', { name: 'Primary navigation', exact: true })
  await expect(nav).toBeVisible()
  await expect(nav.getByRole('link', { name: 'Find my tickets' })).toHaveAttribute('href', '/orders/recover')
  await expect(page.locator('header').getByRole('link', { name: 'Sign up', exact: true })).toHaveAttribute('href', '/sign-up')
  await expect(page.getByRole('button', { name: 'Toggle menu' })).toBeHidden()
  await page.getByRole('button', { name: 'Search events', exact: true }).click()
  expect(await page.locator('header').evaluate(el => el.getBoundingClientRect().height)).toBe(65)
  await page.getByPlaceholder('Search events...').fill('music')
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(1024)
  await nav.getByRole('link', { name: 'Find my tickets' }).click()
  await expect(page.getByRole('heading', { name: 'Find your order', exact: true })).toBeVisible()
})

test('mobile filters disclose, count, persist through reload and clear', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await prepare(page)
  await page.goto('/events?price=free&village=Hag%C3%A5t%C3%B1a')
  const filters = page.getByRole('button', { name: 'Filters (2)' })
  await expect(filters).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByLabel('Price', { exact: true })).toBeHidden()
  await filters.click()
  await expect(filters).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByLabel('Village', { exact: true })).toHaveValue('Hagåtña')
  await page.getByLabel('When', { exact: true }).selectOption('weekend')
  await expect(page.getByRole('button', { name: 'Filters (3)' })).toBeVisible()
  await expect(page).toHaveURL(/date=weekend/)
  await page.reload()
  await page.getByRole('button', { name: 'Filters (3)' }).click()
  await expect(page.getByLabel('When', { exact: true })).toHaveValue('weekend')
  await expect(page.getByLabel('Price', { exact: true })).toHaveValue('free')
  await page.getByLabel('Search events and venues', { exact: true }).fill('nothing')
  await page.getByRole('button', { name: 'Clear filters', exact: true }).click()
  await expect(page).toHaveURL(/\/events$/)
  await expect(page.getByRole('button', { name: 'Filters', exact: true })).toBeVisible()
  await expect(page.locator('.event-card')).toHaveCount(3)
})

test('mobile guest links support recovery and keyboard menu close', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await prepare(page)
  await page.goto('/')
  const toggle = page.getByRole('button', { name: 'Toggle menu' })
  await toggle.click()
  const nav = page.getByRole('navigation', { name: 'Mobile navigation', exact: true })
  await expect(nav.getByRole('link', { name: 'Find my tickets' })).toHaveAttribute('href', '/orders/recover')
  await expect(nav.getByRole('link', { name: 'Sign up', exact: true })).toHaveAttribute('href', '/sign-up')
  await nav.getByRole('link', { name: 'Find my tickets' }).focus()
  await page.keyboard.press('Escape')
  await expect(toggle).toBeFocused()
  await expect(nav).toHaveCount(0)
})

// Round-2 regression checks share measurements with the visual evidence runner.
for (const width of [320, 390, 1024, 1280]) {
  test(`cards and buyer selects stay readable at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 })
    await prepareRound2(page)
    await page.goto('/events')
    const cards = await verifyCardRows(page)
    if (width >= 1024) expect(new Set(cards.map(card => Math.round(card.left))).size).toBe(3)
    if (width < 640) await page.getByRole('button', { name: /^Filters/ }).click()
    for (const id of ['event-date-range', 'event-price', 'event-village']) await verifySelect(page.locator(`#${id}`))
    if (width < 640) await verifySelect(page.locator('#event-category'))
    await page.goto('/')
    for (const id of ['home-when', 'home-where']) await verifySelect(page.locator(`#${id}`))
  })
}

for (const width of [320, 390, 1024, 1280]) {
  test(`checkout keeps help reachable and its zone together at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 })
    await prepareRound2(page)
    await openCheckout(page)
    await verifyCheckout(page)
  })
}

for (const width of [390, 1280]) {
  test(`shared selects preserve admin filters and organizer drafts at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 })
    await prepareRound2(page)
    await page.goto('/admin/refund_reconciliation')
    const status = page.getByRole('combobox', { name: 'Status', exact: true })
    await verifySelect(status)
    await verifySelect(page.getByRole('combobox', { name: 'Age', exact: true }))
    await status.selectOption('failed')
    await page.reload()
    await expect(page.getByRole('combobox', { name: 'Status', exact: true })).toHaveValue('failed')
    await page.goto('/dashboard/events/new')
    await verifySelect(page.getByLabel('Category', { exact: true }))
    const age = page.getByLabel('Age Restriction', { exact: true })
    await verifySelect(age)
    await age.selectOption('eighteen_plus')
    await page.reload()
    await expect(page.getByLabel('Age Restriction', { exact: true })).toHaveValue('eighteen_plus')
  })
}


test('checkout configuration failure keeps cached support reachable at 390px', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await prepareRound2(page)
  await page.goto('/events/community-night')
  await expect(page.locator('footer').getByRole('link', { name: 'Contact support', exact: true })).toHaveAttribute('href', /^mailto:shimizutechnology@gmail\.com\?/)
  await page.getByRole('button', { name: 'Increase quantity for General admission', exact: true }).click()
  await page.route('**/api/v1/config', route => route.fulfill({ status: 503, json: { error: 'Synthetic config outage' } }))
  await page.getByRole('button', { name: /Buy Tickets/ }).click()
  await expect(page.getByRole('button', { name: 'Retry', exact: true })).toBeVisible()
  await expect(page.locator('main').getByRole('link', { name: 'Contact support', exact: true })).toHaveAttribute('href', /^mailto:shimizutechnology@gmail\.com\?/)
  await expect(page.locator('main').getByRole('link', { name: '(671) 483-0219', exact: true })).toHaveAttribute('href', 'tel:6714830219')
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
})
